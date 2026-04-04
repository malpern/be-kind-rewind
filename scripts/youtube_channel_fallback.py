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

    source = None
    videos = None
    scrapetube_error = None

    try:
        videos = parse_scrapetube_videos(args.channel_id, args.max_results)
        source = "scrapetube"
    except Exception as exc:
        scrapetube_error = str(exc)

    if videos is None:
        try:
            videos = parse_rss_videos(args.channel_id, args.max_results)
            source = "rss"
        except Exception as exc:
            if scrapetube_error:
                print(
                    f"Fallback discovery failed. scrapetube: {scrapetube_error}. rss: {exc}",
                    file=sys.stderr,
                )
            else:
                print(f"Fallback discovery failed: {exc}", file=sys.stderr)
            return 1

    print(json.dumps({"source": source, "videos": videos}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
