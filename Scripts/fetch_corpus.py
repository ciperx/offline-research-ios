#!/usr/bin/env python3
"""Fetch the bundled corpus: plain-text English Wikipedia extracts for Corpus/topics.txt.

Runs ONCE at build time on a machine with network access. The resulting
Corpus/raw/wiki.jsonl is committed to the repo, so the shipped app never needs
the network.

Usage:
    python3 Scripts/fetch_corpus.py                      # all topics
    python3 Scripts/fetch_corpus.py --limit 200          # the count used for the shipped corpus
    python3 Scripts/fetch_corpus.py --limit 40 --out /tmp/smoke.jsonl
    python3 Scripts/fetch_corpus.py --resume             # keep articles already fetched

Output:
    Corpus/raw/wiki.jsonl     one JSON object per article (title, url, extract, license)
    Corpus/raw/manifest.json  provenance, counts, SHA-256 of the JSONL and topic list

Source text is licensed CC BY-SA 4.0. Attribution is recorded per article in
wiki.jsonl and aggregated in ATTRIBUTION.md.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.parse
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

API = "https://en.wikipedia.org/w/api.php"
UA = "OfflineResearchIOS/1.0 (corpus builder; one-off build-time fetch)"
BATCH = 20
MIN_CHARS = 800


def read_topics(path: str) -> list[str]:
    seen: set[str] = set()
    topics: list[str] = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            t = line.strip()
            if not t or t.startswith("#"):
                continue
            key = t.casefold()
            if key in seen:
                continue
            seen.add(key)
            topics.append(t)
    return topics


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def trim(text: str, max_chars: int) -> tuple[str, bool]:
    """Cut to <= max_chars on a sentence boundary."""
    if max_chars <= 0 or len(text) <= max_chars:
        return text, False
    cut = text[:max_chars]
    for sep in (". ", ".\n", "? ", "! "):
        idx = cut.rfind(sep)
        if idx > max_chars * 0.6:
            return cut[: idx + 1].strip(), True
    return cut.rsplit(" ", 1)[0].strip() + " …", True


def fetch_one(title: str) -> dict:
    """One article per request.

    Full-text (non-intro) extracts are returned for a single page per request:
    with several titles the API returns empty `extract` strings for all but the
    first, so batching titles is not usable here.
    """
    params = {
        "action": "query",
        "format": "json",
        "formatversion": "2",
        "prop": "extracts|info",
        "inprop": "url",
        "explaintext": "1",
        "redirects": "1",
        "titles": title,
        "maxlag": "5",
    }
    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            # 429 is the common one: the API wants fewer parallel requests, so back off
            # hard and honour Retry-After when present.
            retry_after = exc.headers.get("Retry-After") if exc.headers else None
            wait = float(retry_after) if retry_after and retry_after.isdigit() else (8.0 * (attempt + 1))
            print(f"  HTTP {exc.code} for {title!r}; sleeping {wait:.0f}s", file=sys.stderr)
            time.sleep(wait)
        except Exception as exc:  # noqa: BLE001 - retry any transport error
            wait = 2 ** attempt
            print(f"  retry {attempt + 1}/6 for {title!r} after {exc!r}", file=sys.stderr)
            time.sleep(wait)
    raise RuntimeError(f"failed to fetch {title!r}")


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)

    ap = argparse.ArgumentParser()
    ap.add_argument("--topics", default=os.path.join(root, "Corpus", "topics.txt"))
    ap.add_argument("--out", default=os.path.join(root, "Corpus", "raw", "wiki.jsonl"))
    ap.add_argument("--manifest", default=os.path.join(root, "Corpus", "raw", "manifest.json"))
    ap.add_argument("--limit", type=int, default=0, help="only fetch the first N topics")
    ap.add_argument("--max-chars", type=int, default=12000, help="trim each extract (0 = no trim)")
    ap.add_argument("--resume", action="store_true", help="keep articles already in --out")
    ap.add_argument("--workers", type=int, default=1, help="parallel API requests (keep at 1; the API rate-limits bursts)")
    ap.add_argument("--sleep", type=float, default=0.0, help="pause after the worker pool drains")
    ap.add_argument("--per-request-delay", type=float, default=1.0, help="seconds to wait after each article")
    args = ap.parse_args()

    topics = read_topics(args.topics)
    if args.limit:
        topics = topics[: args.limit]

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    articles: dict[str, dict] = {}
    if args.resume and os.path.exists(args.out):
        with open(args.out, encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    rec = json.loads(line)
                    articles[rec["title"].casefold()] = rec
        print(f"resume: {len(articles)} articles already present")

    have = set(articles)
    todo = [t for t in topics if t.casefold() not in have]
    print(f"topics={len(topics)} todo={len(todo)} max_chars={args.max_chars}")

    skipped: list[str] = []
    truncated = 0
    workers = max(1, args.workers)

    def handle(title: str) -> None:
        nonlocal truncated
        page = None
        data = fetch_one(title)
        if args.per_request_delay:
            time.sleep(args.per_request_delay)
        pages = data.get("query", {}).get("pages", [])
        if isinstance(pages, dict):
            pages = list(pages.values())
        if pages:
            page = pages[0]
        if page is None or page.get("missing") or not page.get("title"):
            skipped.append(f"{title}: missing page")
            return
        extract = (page.get("extract") or "").strip()
        if len(extract) < MIN_CHARS:
            skipped.append(f"{title}: extract too short ({len(extract)} chars)")
            return
        extract, was_trimmed = trim(extract, args.max_chars)
        if was_trimmed:
            truncated += 1
        articles[page["title"].casefold()] = {
            "title": page["title"],
            "pageid": page.get("pageid"),
            "url": page.get("fullurl")
            or "https://en.wikipedia.org/wiki/" + urllib.parse.quote(page["title"].replace(" ", "_")),
            "extract": extract,
            "chars": len(extract),
            "truncated": was_trimmed,
            "license": "CC BY-SA 4.0",
            "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
            "source": "en.wikipedia.org (action=query prop=extracts explaintext)",
            "retrieved": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }

    done = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(handle, t): t for t in todo}
        for fut in as_completed(futures):
            done += 1
            try:
                fut.result()
            except Exception as exc:  # noqa: BLE001
                skipped.append(f"{futures[fut]}: {exc!r}")
            if done % 20 == 0 or done == len(todo):
                print(f"[{done}/{len(todo)}] fetched={len(articles)} skipped={len(skipped)}", flush=True)
        time.sleep(args.sleep)

    ordered = [articles[t.casefold()] for t in topics if t.casefold() in articles]
    with open(args.out, "w", encoding="utf-8") as fh:
        for rec in ordered:
            fh.write(json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n")

    chars = sum(r["chars"] for r in ordered)
    manifest = {
        "corpus": "wikipedia-extracts",
        "api": API,
        "retrieved": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "topics_total": len(topics),
        "articles": len(ordered),
        "articles_truncated": truncated,
        "max_chars_per_article": args.max_chars,
        "characters": chars,
        "approx_words": chars // 6,
        "skipped": skipped,
        "license": "CC BY-SA 4.0",
        "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
        "attribution": "Text adapted from English Wikipedia. Per-article links in ATTRIBUTION.md.",
        "files": {
            os.path.basename(args.topics): {"sha256": sha256_file(args.topics)},
            os.path.basename(args.out): {
                "sha256": sha256_file(args.out),
                "bytes": os.path.getsize(args.out),
                "lines": len(ordered),
            },
        },
    }
    with open(args.manifest, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
        fh.write("\n")

    print(f"wrote {args.out}: {len(ordered)} articles, {chars} chars (~{chars // 6} words)")
    print(f"sha256 {manifest['files'][os.path.basename(args.out)]['sha256']}")
    if skipped:
        print(f"skipped {len(skipped)}:")
        for s in skipped[:25]:
            print("  -", s)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
