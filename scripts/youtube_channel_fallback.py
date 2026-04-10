#!/usr/bin/env python3

import argparse
import json
import sys
import urllib.request
import xml.etree.ElementTree as ET


def compact(text):
    return " ".join((text or "").split())


def parse_scrapetube_videos(channel_id: str, max_results: int):
    import scrapetube  # type: ignore

    videos = []
    entries = scrapetube.get_channel(channel_id=channel_id, limit=max_results, sort_by="newest")
    for entry in entries:
        video_id = entry.get("videoId")
        if not video_id:
            continue

        title_runs = (((entry.get("title") or {}).get("runs")) or [])
        title = title_runs[0].get("text") if title_runs else None

        channel_runs = (((entry.get("longBylineText") or {}).get("runs")) or [])
        channel_title = channel_runs[0].get("text") if channel_runs else None

        published = (entry.get("publishedTimeText") or {}).get("simpleText")
        view_count = (entry.get("viewCountText") or {}).get("simpleText")

        duration = None
        for overlay in entry.get("thumbnailOverlays") or []:
            renderer = overlay.get("thumbnailOverlayTimeStatusRenderer")
            if renderer:
                duration = renderer.get("text", {}).get("simpleText")
                break

        videos.append(
            {
                "videoId": video_id,
                "title": compact(title) or "Untitled",
                "channelTitle": compact(channel_title) or None,
                "publishedAt": compact(published) or None,
                "duration": compact(duration) or None,
                "viewCount": compact(view_count) or None,
            }
        )

    return videos


def parse_rss_videos(channel_id: str, max_results: int):
    feed_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"
    with urllib.request.urlopen(feed_url, timeout=20) as response:
        xml_data = response.read()

    root = ET.fromstring(xml_data)
    ns = {
        "atom": "http://www.w3.org/2005/Atom",
        "yt": "http://www.youtube.com/xml/schemas/2015",
        "media": "http://search.yahoo.com/mrss/",
    }

    videos = []
    for entry in root.findall("atom:entry", ns)[:max_results]:
        video_id = entry.findtext("yt:videoId", default="", namespaces=ns)
        if not video_id:
            continue

        title = entry.findtext("atom:title", default="Untitled", namespaces=ns)
        channel_title = entry.findtext("author/atom:name", default=None, namespaces=ns)
        published_at = entry.findtext("atom:published", default=None, namespaces=ns)

        videos.append(
            {
                "videoId": video_id,
                "title": compact(title) or "Untitled",
                "channelTitle": compact(channel_title) if channel_title else None,
                "publishedAt": published_at,
                "duration": None,
                "viewCount": None,
            }
        )

    return videos


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--channel-id", required=True)
    parser.add_argument("--max-results", type=int, default=16)
    args = parser.parse_args()

    # Fetch BOTH scrapetube (deep historical archive) AND the YouTube RSS feed
    # (always-fresh latest 15) and merge them. RSS catches Shorts and recent
    # uploads that scrapetube's /videos shelf walker silently misses, AND
    # provides accurate ISO 8601 timestamps instead of relative strings.
    # When the same video appears in both, RSS wins (better metadata).
    scrapetube_videos = []
    rss_videos = []
    scrapetube_error = None
    rss_error = None

    try:
        scrapetube_videos = parse_scrapetube_videos(args.channel_id, args.max_results)
    except Exception as exc:
        scrapetube_error = str(exc)

    try:
        rss_videos = parse_rss_videos(args.channel_id, args.max_results)
    except Exception as exc:
        rss_error = str(exc)

    # If both sources failed, surface both errors and exit non-zero so the
    # caller's failure-pattern detector can pick it up.
    if not scrapetube_videos and not rss_videos:
        if scrapetube_error and rss_error:
            print(
                f"Fallback discovery failed. scrapetube: {scrapetube_error}. rss: {rss_error}",
                file=sys.stderr,
            )
        elif scrapetube_error:
            print(f"Fallback discovery failed: {scrapetube_error}", file=sys.stderr)
        elif rss_error:
            print(f"Fallback discovery failed: {rss_error}", file=sys.stderr)
        else:
            print("Fallback discovery returned no videos", file=sys.stderr)
        return 1

    # Merge: RSS first (newest, accurate timestamps), then scrapetube fills in
    # the historical tail. Dedupe by videoId — first occurrence wins so RSS
    # metadata is preferred for overlapping videos.
    seen = set()
    merged = []
    for video in rss_videos + scrapetube_videos:
        vid = video.get("videoId")
        if not vid or vid in seen:
            continue
        seen.add(vid)
        merged.append(video)

    # Reflect which sources contributed in the response so the Swift caller's
    # telemetry can show what worked. Backwards-compatible with the old
    # single-source field — if one source failed, we still report the other.
    if rss_videos and scrapetube_videos:
        source = "scrapetube+rss"
    elif rss_videos:
        source = "rss"
    elif scrapetube_videos:
        source = "scrapetube"
    else:
        source = "none"

    print(json.dumps({"source": source, "videos": merged}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
