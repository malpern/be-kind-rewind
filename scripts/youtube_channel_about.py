#!/usr/bin/env python3
"""
Fetch a YouTube channel's /about page and extract external links.

The /about page embeds a JSON blob in `var ytInitialData = {...}` that
contains the channel's external links (Twitter, GitHub, personal website,
etc.) under a few different paths depending on YouTube's current layout.
We do a recursive walk for known link container keys and dedupe by URL.

Output JSON shape:
    {
      "channelId": "UC...",
      "links": [
        {"title": "Twitter", "url": "https://twitter.com/..."},
        ...
      ]
    }

Exits non-zero only when the page can't be fetched at all. An empty links
array is a valid result (the channel may not have any links published).
"""

import argparse
import json
import re
import sys
import urllib.parse
import urllib.request


USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)


def fetch_about_html(channel_id: str) -> str:
    """Fetch the channel /about page HTML. Honors the system locale via
    Accept-Language so the response shape is the standard YouTube layout."""
    url = f"https://www.youtube.com/channel/{channel_id}/about"
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept-Language": "en-US,en;q=0.9",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8", errors="ignore")


def extract_yt_initial_data(html: str):
    """Find and parse the ytInitialData JSON blob from the channel about
    page HTML. Returns the parsed dict, or None if not found / invalid."""
    patterns = [
        r"var ytInitialData = (\{.+?\});\s*</script>",
        r'window\["ytInitialData"\]\s*=\s*(\{.+?\});',
        r"var ytInitialData\s*=\s*(\{.+?\});\s*var",
    ]
    for pattern in patterns:
        match = re.search(pattern, html, re.DOTALL)
        if not match:
            continue
        raw = match.group(1)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            continue
    return None


def unwrap_redirect(url: str) -> str:
    """YouTube link entries often wrap external URLs in a /redirect?q=
    landing URL. Unwrap to the underlying target so callers store the
    real URL, not YouTube's tracker."""
    parsed = urllib.parse.urlparse(url)
    if parsed.netloc.endswith("youtube.com") and parsed.path == "/redirect":
        params = urllib.parse.parse_qs(parsed.query)
        if "q" in params and params["q"]:
            return urllib.parse.unquote(params["q"][0])
    return url


LINK_CONTAINER_KEYS = {
    "primaryLinks",
    "secondaryLinks",
    "headerLinks",
    "links",
    "externalLinks",
}


def collect_links(node, accumulator: list) -> None:
    """Recursively walk the ytInitialData tree looking for link containers.
    YouTube changes the schema occasionally so we look at multiple known
    keys and try a few extraction patterns per entry. Dedupe happens at the
    end via a seen-set on URL."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key in LINK_CONTAINER_KEYS and isinstance(value, list):
                for entry in value:
                    extract_link_entry(entry, accumulator)
            collect_links(value, accumulator)
    elif isinstance(node, list):
        for item in node:
            collect_links(item, accumulator)


def extract_link_entry(entry, accumulator: list) -> None:
    """Pull title + url from a single link entry. Tries the known nested
    schemas YouTube uses across different layout versions. Skips entries
    where either field is missing."""
    if not isinstance(entry, dict):
        return

    title = None
    url = None

    # Schema A: channelExternalLinkViewModel (modern)
    view_model = entry.get("channelExternalLinkViewModel")
    if isinstance(view_model, dict):
        title_node = view_model.get("title") or {}
        link_node = view_model.get("link") or {}
        title = title_node.get("content") if isinstance(title_node, dict) else None
        url = link_node.get("content") if isinstance(link_node, dict) else None

    # Schema B: channelExternalLinkRenderer (legacy)
    if not url:
        renderer = entry.get("channelExternalLinkRenderer")
        if isinstance(renderer, dict):
            title_runs = (((renderer.get("title") or {}).get("simpleText"))
                          or first_run_text((renderer.get("title") or {}).get("runs")))
            link_runs = (((renderer.get("link") or {}).get("simpleText"))
                         or first_run_text((renderer.get("link") or {}).get("runs")))
            title = title or title_runs
            url = link_runs

    # Schema C: navigationEndpoint with urlEndpoint
    if isinstance(entry.get("navigationEndpoint"), dict) and not url:
        url_endpoint = entry["navigationEndpoint"].get("urlEndpoint")
        if isinstance(url_endpoint, dict):
            url = url_endpoint.get("url")

    if not title or not url:
        return

    cleaned_url = unwrap_redirect(url)
    if not cleaned_url.startswith("http"):
        return

    accumulator.append({
        "title": title.strip(),
        "url": cleaned_url.strip(),
    })


def first_run_text(runs):
    if isinstance(runs, list) and runs:
        first = runs[0]
        if isinstance(first, dict):
            return first.get("text")
    return None


def dedupe_links(links: list) -> list:
    """Deduplicate by URL while preserving the original ordering. Many
    creators have the same link surfaced under multiple containers."""
    seen = set()
    result = []
    for link in links:
        url = link.get("url")
        if not url or url in seen:
            continue
        seen.add(url)
        result.append(link)
    return result


URL_REGEX = re.compile(
    r"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+",
    re.IGNORECASE,
)

# Known link-shortener domains. URLs at these hosts get expanded via a HEAD
# request so callers see the canonical destination instead of the cryptic
# shortener. Adding a domain here is the only thing required to enable
# expansion for it.
SHORTENER_DOMAINS = {
    "bit.ly",
    "amzn.to",
    "amzn.com",
    "ow.ly",
    "tinyurl.com",
    "goo.gl",
    "t.ly",
    "lnkd.in",
    "buff.ly",
    "rebrand.ly",
    "tiny.cc",
    "shorturl.at",
    "is.gd",
    "soo.gd",
}


def expand_shortener(url: str, max_hops: int = 3) -> str:
    """If `url` points at a known shortener domain, follow the redirect chain
    via HEAD requests until we hit a non-shortener or run out of hops.
    Returns the original URL on any failure (network error, non-redirect,
    etc.) so callers always get *something* back.

    Capped at 3 hops to avoid runaway redirect loops. Some shorteners
    chain through 2-3 intermediates before reaching the canonical URL."""
    current = url
    for _ in range(max_hops):
        parsed = urllib.parse.urlparse(current)
        host = parsed.netloc.lower()
        if host.startswith("www."):
            host = host[4:]
        if host not in SHORTENER_DOMAINS:
            return current
        try:
            request = urllib.request.Request(
                current,
                headers={"User-Agent": USER_AGENT},
                method="HEAD",
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                # urllib auto-follows redirects unless we override; the final
                # URL is in response.url. If the server doesn't redirect at
                # all (returns 200 directly), we still get back the same URL
                # and the loop terminates on the next pass.
                final_url = response.url
                if final_url and final_url != current:
                    current = final_url
                    continue
                return current
        except Exception:
            # Network error, blocked, etc. — fall back to whatever we have.
            return current
    return current

# Domain → friendly title for the most common social/professional platforms.
# Order matters: substring match against the URL host. First match wins.
DOMAIN_TITLE_RULES = [
    ("github.com", "GitHub"),
    ("gitlab.com", "GitLab"),
    ("twitter.com", "Twitter/X"),
    ("x.com", "Twitter/X"),
    ("threads.net", "Threads"),
    ("instagram.com", "Instagram"),
    ("tiktok.com", "TikTok"),
    ("linkedin.com", "LinkedIn"),
    ("mastodon.", "Mastodon"),
    ("bsky.app", "Bluesky"),
    ("discord.gg", "Discord"),
    ("discord.com/invite", "Discord"),
    ("patreon.com", "Patreon"),
    ("ko-fi.com", "Ko-fi"),
    ("buymeacoffee.com", "Buy Me a Coffee"),
    ("substack.com", "Substack"),
    ("medium.com", "Medium"),
    ("dev.to", "DEV"),
    ("twitch.tv", "Twitch"),
    ("amazon.com", "Amazon"),
    ("amzn.to", "Amazon"),
    ("amazon.co.uk", "Amazon UK"),
    ("itch.io", "itch.io"),
    ("notion.so", "Notion"),
    ("podcasts.apple.com", "Apple Podcasts"),
    ("open.spotify.com", "Spotify"),
    ("youtube.com/playlist", "YouTube Playlist"),
    ("vimeo.com", "Vimeo"),
    ("soundcloud.com", "SoundCloud"),
    ("steamcommunity.com", "Steam"),
]

# URLs we never want to surface even if they appear in descriptions.
# The bare youtube domain is the channel itself; ad/tracker domains add noise.
URL_BLACKLIST_DOMAINS = {
    "youtu.be",
    "youtube.com",
    "googleusercontent.com",
    "yt3.ggpht.com",
    "googleapis.com",
    "doubleclick.net",
    "google-analytics.com",
}


def title_for_url(url: str) -> str:
    """Map a URL to a friendly display title. Falls back to the bare host if
    no platform rule matches."""
    lower = url.lower()
    for needle, label in DOMAIN_TITLE_RULES:
        if needle in lower:
            return label
    parsed = urllib.parse.urlparse(url)
    host = parsed.netloc
    if host.startswith("www."):
        host = host[4:]
    return host or url


def extract_links_from_description(text: str) -> list:
    """Pull URLs out of free text and return them as link entries with
    derived titles. Used as the primary extraction path because YouTube's
    /about tab is now lazy-loaded via continuation calls but the channel
    home page's og:description still embeds the channel description inline.

    URLs at known shortener domains (bit.ly, amzn.to, etc.) are expanded
    via a HEAD request so the caller sees the canonical destination."""
    if not text:
        return []
    found = []
    for match in URL_REGEX.finditer(text):
        url = match.group(0).rstrip(".,);:!?")
        # Resolve shortener redirects BEFORE filtering, since the shortener
        # itself usually points at a real destination outside the blacklist.
        resolved = expand_shortener(url)
        parsed = urllib.parse.urlparse(resolved)
        host_root = ".".join(parsed.netloc.lower().split(".")[-2:])
        if host_root in URL_BLACKLIST_DOMAINS:
            continue
        found.append({"title": title_for_url(resolved), "url": resolved})
    return found


def fetch_channel_home_html(channel_id: str) -> str:
    """Fetch the channel home page (not /about). The home page exposes the
    channel description inside an og:description meta tag, which has been
    much more stable across layout changes than the /about tab data."""
    url = f"https://www.youtube.com/channel/{channel_id}"
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept-Language": "en-US,en;q=0.9",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8", errors="ignore")


def extract_og_description(html: str) -> str:
    """Pull the og:description meta tag value. YouTube embeds the channel's
    description here verbatim, including any URLs the creator listed."""
    match = re.search(
        r'<meta\s+property="og:description"\s+content="([^"]*)"',
        html,
        re.IGNORECASE,
    )
    if match:
        return match.group(1)
    return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--channel-id", required=True)
    args = parser.parse_args()

    accumulator = []
    fetch_errors = []

    # Path 1 (primary): channel home page → og:description → URL regex.
    # Reliable across YouTube layout changes because og: meta tags are public
    # API contracts that other consumers (Twitter cards, etc.) rely on.
    try:
        home_html = fetch_channel_home_html(args.channel_id)
        og_text = extract_og_description(home_html)
        for link in extract_links_from_description(og_text):
            accumulator.append(link)
    except Exception as exc:
        fetch_errors.append(f"home: {exc}")

    # Path 2 (forward-compat): /about page ytInitialData walk. Currently
    # returns nothing because /about is lazy-loaded, but if YouTube ever
    # restores inline link data this path picks it up automatically.
    try:
        about_html = fetch_about_html(args.channel_id)
        initial_data = extract_yt_initial_data(about_html)
        if initial_data is not None:
            collect_links(initial_data, accumulator)
        # Also try the og:description on the about page in case the home
        # page didn't have one.
        about_og = extract_og_description(about_html)
        for link in extract_links_from_description(about_og):
            accumulator.append(link)
    except Exception as exc:
        fetch_errors.append(f"about: {exc}")

    # If both paths errored AND we got nothing, surface the failure so the
    # caller's error pattern detector can pick it up. Empty links from a
    # successful fetch is a valid result.
    if not accumulator and fetch_errors:
        print(
            f"Failed to fetch channel about info: {'; '.join(fetch_errors)}",
            file=sys.stderr,
        )
        return 1

    links = dedupe_links(accumulator)
    print(json.dumps({
        "channelId": args.channel_id,
        "links": links,
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
