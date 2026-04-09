#!/usr/bin/env python3
"""Search YouTube videos without the YouTube Data API.

Uses scrapetube (which scrapes YouTube's internal API) to search for videos.
No API key or quota needed.

Usage:
    python3 youtube_search_fallback.py --query "mechanical keyboard review" --max-results 5

Output (JSON):
    {"source": "scrapetube", "videos": [{"videoId": "...", "title": "...", ...}]}
"""

import argparse
import json
import sys


def compact(text):
    return " ".join((text or "").split())


def search_videos(query, max_results=5):
    import scrapetube  # type: ignore

    videos = []
    for entry in scrapetube.get_search(query, limit=max_results):
        video_id = entry.get("videoId")
        if not video_id:
            continue

        title_runs = ((entry.get("title") or {}).get("runs")) or []
        title = title_runs[0].get("text") if title_runs else None

        channel_runs = ((entry.get("longBylineText") or {}).get("runs")) or []
        channel_title = channel_runs[0].get("text") if channel_runs else None

        # Extract channel ID from browse endpoint
        channel_id = None
        for run in channel_runs:
            endpoint = (run.get("navigationEndpoint") or {}).get("browseEndpoint") or {}
            cid = endpoint.get("browseId")
            if cid:
                channel_id = cid
                break

        published = (entry.get("publishedTimeText") or {}).get("simpleText")
        view_count = (entry.get("viewCountText") or {}).get("simpleText")

        duration = None
        for overlay in entry.get("thumbnailOverlays") or []:
            renderer = overlay.get("thumbnailOverlayTimeStatusRenderer")
            if renderer:
                duration = renderer.get("text", {}).get("simpleText")
                break

        videos.append({
            "videoId": video_id,
            "title": compact(title) or "Untitled",
            "channelId": channel_id,
            "channelTitle": compact(channel_title),
            "publishedAt": compact(published),
            "duration": compact(duration),
            "viewCount": compact(view_count),
        })

    return videos


def main():
    parser = argparse.ArgumentParser(description="Search YouTube without API")
    parser.add_argument("--query", required=True, help="Search query")
    parser.add_argument("--max-results", type=int, default=5)
    args = parser.parse_args()

    try:
        videos = search_videos(args.query, args.max_results)
        json.dump({"source": "scrapetube", "videos": videos}, sys.stdout)
    except Exception as exc:
        print(f"Search fallback failed: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
