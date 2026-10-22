#!/usr/bin/env python3
"""Build the bundled FTS5 index from Corpus/raw/wiki.jsonl.

Output: App/Resources/corpus.sqlite (committed) + Corpus/index_manifest.json
(provenance, counts, SHA-256). Deterministic: same input -> same chunk ids.

Chunking: paragraph-aware, ~200 whitespace tokens per chunk with 40 tokens of
overlap, so a claim split across a paragraph boundary stays retrievable.

Schema (read-only at runtime; mirrored in App/Sources/Retrieval/CorpusStore.swift):

    meta(key TEXT PRIMARY KEY, value TEXT)
    docs(id INTEGER PRIMARY KEY, title TEXT, url TEXT, license TEXT, chars INTEGER)
    chunks(id INTEGER PRIMARY KEY, doc_id INTEGER, ordinal INTEGER, text TEXT, tokens INTEGER)
    chunks_fts USING fts5(title, text, chunk_id UNINDEXED, tokenize="unicode61 remove_diacritics 2")

`docs.id` and `chunks.id` are dense (1..N) and follow input order, so the shipped
file is reproducible from the same wiki.jsonl.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
import time

TARGET_TOKENS = 200
OVERLAP_TOKENS = 40
SCHEMA_VERSION = 3

SENT_SPLIT = re.compile(r"(?<=[.!?])\s+")


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def paragraphs(text: str) -> list[str]:
    out = []
    for block in re.split(r"\n\s*\n|\n", text):
        block = " ".join(block.split())
        if len(block) >= 40:
            out.append(block)
    return out


def sentences(par: str) -> list[str]:
    return [s for s in SENT_SPLIT.split(par) if s.strip()]


def chunk_text(extract: str, target: int = TARGET_TOKENS, overlap: int = OVERLAP_TOKENS) -> list[str]:
    """Greedy sentence packing with token overlap between consecutive chunks."""
    sents: list[str] = []
    for par in paragraphs(extract):
        sents.extend(sentences(par))

    chunks: list[str] = []
    buf: list[str] = []

    def tok(s: str) -> int:
        return len(s.split())

    for sent in sents:
        buf.append(sent)
        if sum(tok(s) for s in buf) >= target:
            chunks.append(" ".join(buf).strip())
            # carry the tail sentences (up to `overlap` tokens) into the next chunk
            carry: list[str] = []
            acc = 0
            for s in reversed(buf):
                if acc + tok(s) > overlap:
                    break
                carry.insert(0, s)
                acc += tok(s)
            buf = carry

    if buf:
        tail = " ".join(buf).strip()
        if not chunks or len(tail.split()) > overlap:
            chunks.append(tail)

    # drop near-duplicate chunks created by the overlap carry
    seen: set[str] = set()
    unique: list[str] = []
    for c in chunks:
        key = c[:160]
        if key in seen:
            continue
        seen.add(key)
        unique.append(c)
    return unique


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)

    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default=os.path.join(root, "Corpus", "raw", "wiki.jsonl"))
    ap.add_argument("--out", default=os.path.join(root, "App", "Resources", "corpus.sqlite"))
    ap.add_argument("--manifest", default=os.path.join(root, "Corpus", "index_manifest.json"))
    ap.add_argument("--target-tokens", type=int, default=TARGET_TOKENS)
    ap.add_argument("--overlap-tokens", type=int, default=OVERLAP_TOKENS)
    args = ap.parse_args()

    if not os.path.exists(args.input):
        print(f"missing input: {args.input}\nrun Scripts/fetch_corpus.py first", file=sys.stderr)
        return 2

    articles = []
    with open(args.input, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                articles.append(json.loads(line))
    if not articles:
        print("no articles in input", file=sys.stderr)
        return 2

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    if os.path.exists(args.out):
        os.remove(args.out)

    db = sqlite3.connect(args.out)
    db.executescript(
        """
        PRAGMA page_size = 4096;
        PRAGMA journal_mode = DELETE;
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE docs (
            id      INTEGER PRIMARY KEY,
            title   TEXT NOT NULL,
            url     TEXT NOT NULL,
            license TEXT NOT NULL,
            chars   INTEGER NOT NULL
        );
        CREATE TABLE chunks (
            id      INTEGER PRIMARY KEY,
            doc_id  INTEGER NOT NULL REFERENCES docs(id),
            ordinal INTEGER NOT NULL,
            text    TEXT NOT NULL,
            tokens  INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE chunks_fts USING fts5(
            title,
            text,
            chunk_id UNINDEXED,
            tokenize = "unicode61 remove_diacritics 2"
        );
        """
    )

    chunk_id = 0
    total_chunks = 0
    total_chars = 0
    for doc_id, art in enumerate(articles, start=1):
        text = art["extract"]
        total_chars += len(text)
        db.execute(
            "INSERT INTO docs(id, title, url, license, chars) VALUES (?,?,?,?,?)",
            (doc_id, art["title"], art["url"], art.get("license", "CC BY-SA 4.0"), len(text)),
        )
        for ordinal, chunk in enumerate(chunk_text(text, args.target_tokens, args.overlap_tokens)):
            chunk_id += 1
            total_chunks += 1
            db.execute(
                "INSERT INTO chunks(id, doc_id, ordinal, text, tokens) VALUES (?,?,?,?,?)",
                (chunk_id, doc_id, ordinal, chunk, len(chunk.split())),
            )
            db.execute(
                "INSERT INTO chunks_fts(rowid, title, text, chunk_id) VALUES (?,?,?,?)",
                (chunk_id, art["title"], chunk, chunk_id),
            )

    meta = {
        "schema_version": str(SCHEMA_VERSION),
        "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "articles": str(len(articles)),
        "chunks": str(total_chunks),
        "characters": str(total_chars),
        "target_tokens": str(args.target_tokens),
        "overlap_tokens": str(args.overlap_tokens),
        "source_file": os.path.basename(args.input),
        "source_sha256": sha256_file(args.input),
        "tokenizer": "unicode61 remove_diacritics 2",
        "ranking": "bm25(title, text) via FTS5 bm25()",
    }
    db.executemany("INSERT INTO meta(key, value) VALUES (?,?)", sorted(meta.items()))
    db.commit()
    db.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('optimize')")
    db.commit()
    db.execute("ANALYZE")
    db.commit()
    db.execute("VACUUM")
    db.commit()

    integrity = db.execute("PRAGMA integrity_check").fetchone()[0]
    counts = {
        "docs": db.execute("SELECT count(*) FROM docs").fetchone()[0],
        "chunks": db.execute("SELECT count(*) FROM chunks").fetchone()[0],
        "fts_rows": db.execute("SELECT count(*) FROM chunks_fts").fetchone()[0],
    }
    db.close()

    size = os.path.getsize(args.out)
    manifest = {
        "index": os.path.basename(args.out),
        "path": os.path.relpath(args.out, root),
        "built_at": meta["built_at"],
        "schema_version": SCHEMA_VERSION,
        "articles": len(articles),
        "chunks": total_chunks,
        "characters": total_chars,
        "approx_words": total_chars // 6,
        "chunking": {"target_tokens": args.target_tokens, "overlap_tokens": args.overlap_tokens},
        "counts": counts,
        "integrity_check": integrity,
        "bytes": size,
        "sha256": sha256_file(args.out),
        "source": {"file": os.path.basename(args.input), "sha256": meta["source_sha256"]},
    }
    with open(args.manifest, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
        fh.write("\n")

    print(json.dumps({**counts, "bytes": size, "sha256": manifest["sha256"], "integrity": integrity}, indent=2))
    if integrity != "ok":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
