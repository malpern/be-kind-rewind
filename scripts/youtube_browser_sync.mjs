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

async function waitForText(page, text, timeout = 15000) {
  await page.getByText(text, { exact: false }).waitFor({ timeout });
}

async function ensureSignedIn(page) {
  await page.goto("https://www.youtube.com/", { waitUntil: "domcontentloaded" });
  if (await page.getByText("Sign in", { exact: false }).count()) {
    throw new Error("YouTube browser executor is not signed in. Use the persistent profile and sign in first.");
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

  const dialog = page.locator("ytd-add-to-playlist-renderer").first();
  await dialog.waitFor({ timeout: 15000 });

  const playlistName = action.playlistTitle || action.playlistId;
  const option = dialog.locator("ytd-playlist-add-to-option-renderer").filter({
    has: dialog.getByText(playlistName, { exact: false }).first()
  }).first();
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

  const closeButton = page.getByRole("button", { name: /close/i }).first();
  if (await closeButton.count()) {
    await closeButton.click();
  } else {
    await page.keyboard.press("Escape");
  }
}

async function markNotInterested(page, action) {
  await page.goto(`https://www.youtube.com/watch?v=${action.videoId}`, { waitUntil: "domcontentloaded" });
  const moreButton = page.locator('button[aria-label*="Action menu"]').first();
  await moreButton.click();
  const menuItem = page.getByRole("menuitem", { name: /not interested/i }).first();
  await menuItem.click();
}

async function main() {
  const args = parseArgs(process.argv);
  const actionsPath = args["actions-json"];
  const setupLogin = args["setup-login"] === "true";
  if (!actionsPath && !setupLogin) {
    fail("Missing --actions-json");
  }

  const profileDir = args["profile-dir"] || path.join(os.homedir(), ".config", "be-kind-rewind", "playwright-profile");
  const artifactDir = args["artifact-dir"] || path.join(process.cwd(), "output", "playwright", "browser-sync");
  const headed = args["headed"] !== "false";
  const actions = setupLogin ? [] : await loadActions(actionsPath);

  const context = await chromium.launchPersistentContext(profileDir, {
    headless: !headed,
    viewport: { width: 1440, height: 960 }
  });

  try {
    if (setupLogin) {
      await runLoginSetup(context);
      return;
    }

    const page = context.pages()[0] ?? await context.newPage();
    await ensureSignedIn(page);

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
