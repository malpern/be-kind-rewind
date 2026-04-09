#!/usr/bin/env python3
"""Fetch YouTube channel avatar URLs without using the YouTube Data API.

Scrapes channel pages for the avatar thumbnail URL.
No API key or quota needed.

Usage:
    python3 youtube_channel_icons.py --channel-ids UC123,UC456,...

Output (JSON):
    {"icons": {"UC123": "https://yt3.ggpht.com/...", "UC456": "https://yt3.ggpht.com/..."}}
"""

import argparse
import json
import re
import sys
import urllib.request
import urllib.error


def fetch_channel_icon(channel_id: str) -> str | None:
    """Fetch the avatar URL for a YouTube channel by scraping the channel page."""
    url = f"https://www.youtube.com/channel/{channel_id}"
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        "Accept-Language": "en-US,en;q=0.9",
    })

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            html = response.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError):
        return None

    # Look for avatar URL in the page — it appears in multiple places
    # Pattern 1: og:image meta tag (usually the channel avatar)
    match = re.search(r'<meta\s+property="og:image"\s+content="([^"]+)"', html)
    if match:
        icon_url = match.group(1)
        # og:image can be a banner — check if it looks like an avatar (yt3.ggpht.com)
        if "yt3.ggpht.com" in icon_url:
            return icon_url

    # Pattern 2: channelMetadataRenderer.avatar.thumbnails
    match = re.search(r'"avatar":\s*\{"thumbnails":\s*\[\{"url":\s*"([^"]+)"', html)
    if match:
        return match.group(1)

    # Pattern 3: thumbnail URL in initial data
    match = re.search(r'"thumbnails":\[{"url":"(https://yt3\.ggpht\.com/[^"]+)"', html)
    if match:
        return match.group(1)

    return None


def main():
    parser = argparse.ArgumentParser(description="Fetch YouTube channel avatar URLs")
    parser.add_argument("--channel-ids", required=True, help="Comma-separated channel IDs")
    args = parser.parse_args()

    channel_ids = [cid.strip() for cid in args.channel_ids.split(",") if cid.strip()]
    icons = {}

    for channel_id in channel_ids:
        icon_url = fetch_channel_icon(channel_id)
        if icon_url:
            icons[channel_id] = icon_url

    json.dump({"icons": icons}, sys.stdout)


if __name__ == "__main__":
    main()
