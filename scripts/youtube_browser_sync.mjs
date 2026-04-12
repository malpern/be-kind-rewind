#!/usr/bin/env node

import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { chromium } from "playwright";

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith("--")) continue;
    const value = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : "true";
    args[key.slice(2)] = value;
  }
  return args;
}

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

async function ensureDir(dirPath) {
  await fs.mkdir(dirPath, { recursive: true });
}

async function loadActions(actionsPath) {
  const raw = await fs.readFile(actionsPath, "utf8");
  const payload = JSON.parse(raw);
  if (!Array.isArray(payload.actions)) {
    throw new Error("Invalid actions file");
  }
  return payload.actions;
}

async function loadRelatedRequest(requestPath) {
  const raw = await fs.readFile(requestPath, "utf8");
  const payload = JSON.parse(raw);
  if (!Array.isArray(payload.seedVideoIds)) {
    throw new Error("Invalid related request file");
  }
  return {
    seedVideoIds: [...new Set(payload.seedVideoIds.filter((value) => typeof value === "string" && value.trim().length > 0))],
    maxResultsPerSeed: Math.max(1, Math.min(Number(payload.maxResultsPerSeed) || 4, 8))
  };
}

async function waitForText(page, text, timeout = 15000) {
  await page.getByText(text, { exact: false }).waitFor({ timeout });
}

async function ensureSignedIn(page) {
  await page.goto("https://www.youtube.com/", { waitUntil: "domcontentloaded" });
  const signInLink = page.getByRole("link", { name: /sign in/i }).first();
  const signInButton = page.getByRole("button", { name: /sign in/i }).first();
  if (await signInLink.count() || await signInButton.count()) {
    throw new Error("YouTube browser executor is not signed in. Use the persistent profile and sign in first.");
  }
}

async function checkSignedInStatus(context) {
  const page = context.pages()[0] ?? await context.newPage();
  try {
    await ensureSignedIn(page);
    return { ready: true, message: "Signed in to YouTube" };
  } catch (error) {
    return {
      ready: false,
      message: error instanceof Error ? error.message : String(error)
    };
  }
}

async function runLoginSetup(context) {
  const page = context.pages()[0] ?? await context.newPage();
  await page.goto("https://www.youtube.com/", { waitUntil: "domcontentloaded" });
  process.stdout.write("Browser profile opened. Sign in to YouTube in the Playwright window, then press Ctrl+C when finished.\n");
  await new Promise(() => {});
}

async function saveToPlaylist(page, action) {
  await page.goto(`https://www.youtube.com/watch?v=${action.videoId}`, { waitUntil: "domcontentloaded" });
  const saveButton = page.getByRole("button", { name: /save/i }).first();
  await saveButton.click();

  const playlistName = action.playlistTitle || action.playlistId;
  const legacyDialog = page.locator("ytd-add-to-playlist-renderer").first();
  const modernSheet = page.locator("yt-list-item-view-model[aria-label], toggleable-list-item-view-model").first();

  await Promise.race([
    legacyDialog.waitFor({ timeout: 15000 }),
    modernSheet.waitFor({ timeout: 15000 })
  ]);

  if (await legacyDialog.count()) {
    const option = legacyDialog.locator("ytd-playlist-add-to-option-renderer").filter({
      has: legacyDialog.getByText(playlistName, { exact: false }).first()
    }).first();
    if (await option.count()) {
      await option.waitFor({ timeout: 15000 });

      const checkbox = option.locator('[role="checkbox"], tp-yt-paper-checkbox').first();
      await checkbox.waitFor({ timeout: 15000 });

      const checkboxState = await checkbox.evaluate((node) => {
        const element = /** @type {HTMLElement} */ (node);
        const ariaChecked = element.getAttribute("aria-checked");
        if (ariaChecked) return ariaChecked;
        if ("checked" in element) {
          return element.checked ? "true" : "false";
        }
        return "unknown";
      });

      if (checkboxState !== "true") {
        await checkbox.click();
        await page.waitForTimeout(500);
        const updatedState = await checkbox.getAttribute("aria-checked");
        if (updatedState !== "true") {
          throw new Error(`Could not confirm playlist selection for ${playlistName}.`);
        }
      }
    } else {
      throw new Error(`Could not find playlist option for ${playlistName} in legacy playlist dialog.`);
    }
  } else {
    const option = page.locator("yt-list-item-view-model[aria-label]").filter({
      hasText: playlistName
    }).first();
    await option.waitFor({ timeout: 15000 });

    const currentState = await option.evaluate((node) => {
      const element = /** @type {HTMLElement} */ (node);
      const ariaPressed = element.getAttribute("aria-pressed");
      if (ariaPressed) return ariaPressed;
      const ariaLabel = element.getAttribute("aria-label") ?? "";
      if (/selected/i.test(ariaLabel)) return "true";
      return "false";
    });

    if (currentState !== "true") {
      await option.click();
      await page.waitForTimeout(500);

      const updatedState = await option.evaluate((node) => {
        const element = /** @type {HTMLElement} */ (node);
        const ariaPressed = element.getAttribute("aria-pressed");
        if (ariaPressed) return ariaPressed;
        const ariaLabel = element.getAttribute("aria-label") ?? "";
        if (/selected/i.test(ariaLabel)) return "true";
        return "false";
      });

      if (updatedState !== "true") {
        throw new Error(`Could not confirm playlist selection for ${playlistName}.`);
      }
    }
  }

  const closeButton = page.getByRole("button", { name: /close/i }).first();
  if (await closeButton.count()) {
    await closeButton.click();
  } else {
    await page.keyboard.press("Escape");
  }
}

async function markNotInterested(page, action) {
  await page.goto(`https://www.youtube.com/watch?v=${action.videoId}`, { waitUntil: "domcontentloaded" });
  const moreButton = page.locator('button[aria-label*="Action menu"], button[aria-label*="More actions"], ytd-menu-renderer button').first();
  await moreButton.waitFor({ timeout: 15000 });
  await moreButton.click();

  const menuItem = page.getByRole("menuitem", { name: /not interested/i }).first();
  const buttonFallback = page.getByRole("button", { name: /not interested/i }).first();

  if (await menuItem.count()) {
    await menuItem.click();
  } else if (await buttonFallback.count()) {
    await buttonFallback.click();
  } else {
    throw new Error("Could not find the Not Interested action in YouTube's action menu.");
  }

  await page.waitForTimeout(750);
}

async function fetchRelatedVideosForSeed(page, seedVideoId, maxResults) {
  await page.goto(`https://www.youtube.com/watch?v=${seedVideoId}`, { waitUntil: "domcontentloaded" });
  await page.waitForSelector("ytd-watch-next-secondary-results-renderer ytd-compact-video-renderer", { timeout: 20000 });
  await page.waitForTimeout(1200);

  return await page.evaluate(({ seedVideoId, maxResults }) => {
    const compact = (value) => (value || "").replace(/\s+/g, " ").trim();
    const parseVideoId = (href) => {
      try {
        const url = new URL(href, "https://www.youtube.com");
        if (!url.pathname.startsWith("/watch")) return null;
        return url.searchParams.get("v");
      } catch {
        return null;
      }
    };
    const parseChannelId = (href) => {
      if (!href || !href.startsWith("/channel/")) return null;
      return href.split("/channel/")[1]?.split(/[/?#]/)[0] || null;
    };

    const nodes = Array.from(document.querySelectorAll("ytd-watch-next-secondary-results-renderer ytd-compact-video-renderer"));
    const seen = new Set();
    const results = [];

    for (const node of nodes) {
      const titleAnchor = node.querySelector("a#video-title");
      const thumbnailAnchor = node.querySelector("a#thumbnail");
      const href = titleAnchor?.getAttribute("href") || thumbnailAnchor?.getAttribute("href") || "";
      const videoId = parseVideoId(href);
      if (!videoId || videoId === seedVideoId || seen.has(videoId)) continue;
      if (href.includes("list=")) continue;

      const title = compact(titleAnchor?.textContent);
      if (!title) continue;

      const channelAnchor = node.querySelector("ytd-channel-name a, #channel-name a");
      const channelHref = channelAnchor?.getAttribute("href") || "";
      const metadataParts = Array.from(node.querySelectorAll("#metadata-line span"))
        .map((element) => compact(element.textContent))
        .filter(Boolean);
      const duration = compact(node.querySelector("ytd-thumbnail-overlay-time-status-renderer span, #overlays span")?.textContent);

      results.push({
        seedVideoId,
        videoId,
        title,
        channelId: parseChannelId(channelHref),
        channelTitle: compact(channelAnchor?.textContent) || null,
        viewCount: metadataParts[0] || null,
        publishedAt: metadataParts[1] || null,
        duration: duration || null
      });
      seen.add(videoId);

      if (results.length >= maxResults) {
        break;
      }
    }

    return results;
  }, { seedVideoId, maxResults });
}

async function main() {
  const args = parseArgs(process.argv);
  const actionsPath = args["actions-json"];
  const relatedRequestPath = args["fetch-related-json"];
  const setupLogin = args["setup-login"] === "true";
  const checkLogin = args["check-login"] === "true";
  if (!actionsPath && !setupLogin && !checkLogin && !relatedRequestPath) {
    fail("Missing --actions-json");
  }

  const profileDir = args["profile-dir"] || path.join(os.homedir(), ".config", "be-kind-rewind", "playwright-profile");
  const artifactDir = args["artifact-dir"] || path.join(process.cwd(), "output", "playwright", "browser-sync");
  const headed = args["headed"] !== "false";
  const actions = (setupLogin || checkLogin || relatedRequestPath) ? [] : await loadActions(actionsPath);
  const relatedRequest = relatedRequestPath ? await loadRelatedRequest(relatedRequestPath) : null;

  const context = await chromium.launchPersistentContext(profileDir, {
    channel: "chrome",
    headless: !headed,
    viewport: { width: 1440, height: 960 },
    ignoreDefaultArgs: ["--enable-automation", "--no-sandbox"]
  });

  try {
    if (setupLogin) {
      await runLoginSetup(context);
      return;
    }

    if (checkLogin) {
      const status = await checkSignedInStatus(context);
      process.stdout.write(JSON.stringify(status, null, 2));
      return;
    }

    const page = context.pages()[0] ?? await context.newPage();
    await ensureSignedIn(page);

    if (relatedRequest) {
      const results = [];
      for (const seedVideoId of relatedRequest.seedVideoIds) {
        const related = await fetchRelatedVideosForSeed(page, seedVideoId, relatedRequest.maxResultsPerSeed);
        results.push(...related);
      }
      process.stdout.write(JSON.stringify({ results }, null, 2));
      return;
    }

    const successes = [];
    const failures = [];

    await ensureDir(artifactDir);

    for (const action of actions) {
      try {
        if (action.action === "add_to_playlist") {
          await saveToPlaylist(page, action);
        } else if (action.action === "not_interested") {
          await markNotInterested(page, action);
        } else {
          throw new Error(`Unsupported browser action: ${action.action}`);
        }
        successes.push(action.id);
      } catch (error) {
        const prefix = `action-${action.id}-${action.action}`;
        const screenshotPath = path.join(artifactDir, `${prefix}.png`);
        const htmlPath = path.join(artifactDir, `${prefix}.html`);
        try {
          await page.screenshot({ path: screenshotPath, fullPage: true });
          await fs.writeFile(htmlPath, await page.content(), "utf8");
        } catch {
          // Best-effort artifact capture only.
        }
        failures.push({
          id: action.id,
          message: error instanceof Error ? `${error.message} [artifacts: ${prefix}]` : String(error)
        });
      }
    }

    process.stdout.write(JSON.stringify({ successes, failures }, null, 2));
  } finally {
    await context.close();
  }
}

main().catch(error => {
  fail(error instanceof Error ? error.message : String(error));
});
