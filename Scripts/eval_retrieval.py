#!/usr/bin/env python3
"""Retrieval quality harness — mirrors the Swift retriever's query plan.

Runs the *same* pipeline the app uses (QueryTerms strategies -> FTS5 bm25 ->
per-document dedupe -> 3 documents) against App/Resources/corpus.sqlite, so the
numbers here describe shipping behaviour rather than a Python-only variant.

    python3 Scripts/eval_retrieval.py                # human table
    python3 Scripts/eval_retrieval.py --json out.json

Metrics:
    doc@1     expected article is the top-ranked document
    doc@3     expected article is among the three documents sent to the model
              <- this is the number that matters: 3 documents is what the
                 retriever passes to the prompt
    MRR       mean reciprocal rank of the expected document
    miss      expected article absent from the top 64 candidate chunks

No LLM is involved: this measures the retrieval layer in isolation, which is the
only part that can be measured deterministically on any machine.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time

STOPWORDS = set("""
a about above after again against all am an and any are as at be because been before being below
between both but by can cannot could did do does doing don down during each few for from further had
has have having he her here hers herself him himself his how i if in into is it its itself just me
more most my myself no nor not now of off on once only or other our ours ourselves out over own same
she should so some such than that the their theirs them themselves then there these they this those
through to too under until up very was we were what when where which while who whom why will with
would you your yours yourself yourselves explain describe tell give list summary summarize define
definition mean means meaning work works difference differences compare versus vs between please
""".split())

WORD = re.compile(r"[a-z0-9]+(?:['-][a-z0-9]+)*")


def terms(question: str) -> list[str]:
    out: list[str] = []
    for raw in WORD.findall(question.lower()):
        w = raw[:-1] if len(raw) > 3 and raw.endswith("s") and not raw.endswith("ss") else raw
        if len(w) < 2 or w in STOPWORDS or w in out:
            continue
        out.append(w)
    return out


def expression(ts: list[str], op: str, prefix: bool, min_prefix: int = 5) -> str:
    parts = []
    for t in ts:
        esc = t.replace('"', '""')
        parts.append(f'"{esc}"*' if prefix and len(t) >= min_prefix else f'"{esc}"')
    return f" {op} ".join(parts)


def strategies(ts: list[str]) -> list[tuple[str, str]]:
    if not ts:
        return []
    out = []
    if len(ts) >= 2:
        out.append(("and-prefix", expression(ts, "AND", True)))
        out.append(("and", expression(ts, "AND", False)))
    out.append(("or-prefix", expression(ts, "OR", True)))
    out.append(("or", expression(ts, "OR", False)))
    return out


# (question, expected article title). Questions are phrased the way a person would
# ask, not the way the article is titled, so keyword-only matching does not win by
# construction.
EVAL_SET: list[tuple[str, str]] = [
    ("Why does photosynthesis need light if it only stores energy in sugar?",
     "Photosynthesis"),
    ("How do cells make ATP without oxygen?",
     "Cellular respiration"),
    ("How are off-target edits reduced in CRISPR gene editing?",
     "CRISPR gene editing"),
    ("What does a messenger RNA vaccine actually instruct the cell to build?",
     "Messenger RNA"),
    ("How does the immune system tell self from non-self?",
     "Immune system"),
    ("What does the gut microbiota do for its host?",
     "Gut microbiota"),
    ("Why is sleep timing controlled by light exposure?",
     "Circadian rhythm"),
    ("How does the brain reorganise itself after injury?",
     "Neuroplasticity"),
    ("What is the difference between REM and slow wave sleep?",
     "Sleep"),
    ("Why does a positive test not imply a high probability of disease?",
     "Bayesian inference"),
    ("Why do extreme results tend to be followed by average ones?",
     "Regression toward the mean"),
    ("What is a confounding variable and why does it break causal claims?",
     "Confounding"),
    ("Why randomise treatment assignment in a clinical trial?",
     "Randomized controlled trial"),
    ("What does entropy measure in a communication channel?",
     "Information theory"),
    ("How does a Kalman filter combine a prediction with a noisy measurement?",
     "Kalman filter"),
    ("Why does quantisation lose information?",
     "Quantization (signal processing)"),
    ("How does retrieval augmented generation reduce hallucination?",
     "Retrieval-augmented generation"),
    ("Why is a vector database needed for embedding search?",
     "Vector database"),
    ("How does a B-tree keep lookups logarithmic on disk?",
     "B-tree"),
    ("Why does a bloom filter have false positives but no false negatives?",
     "Bloom filter"),
    ("How does TCP congestion control react to packet loss?",
     "TCP congestion control"),
    ("Why does DNS use UDP for most queries?",
     "Domain Name System"),
    ("What problem does network address translation create for peer to peer?",
     "Network address translation"),
    ("How does Reed-Solomon error correction recover corrupted symbols?",
     "Reed–Solomon error correction"),
    ("Why does UTF-8 stay compatible with ASCII?",
     "UTF-8"),
    ("How does a generational garbage collector decide what to free?",
     "Garbage collection (computer science)"),
    ("Why is virtual memory useful when physical RAM is full?",
     "Virtual memory"),
    ("How does a CPU cache exploit locality?",
     "CPU cache"),
    ("How does a RISC pipeline handle a branch misprediction?",
     "RISC-V"),
    ("Why do lithium ion cells degrade with fast charging?",
     "Lithium-ion battery"),
    ("What limits the efficiency of a single junction solar cell?",
     "Solar cell"),
    ("Why does nuclear fusion need such high temperature?",
     "Nuclear fusion"),
    ("What does the double slit experiment show about measurement?",
     "Double-slit experiment"),
    ("Why does time pass differently at different altitudes?",
     "General relativity"),
    ("How does a gravitational lens magnify a distant galaxy?",
     "Gravitational lens"),
    ("Why is delta-v the real currency of space missions?",
     "Delta-v"),
    ("Why is weather forecasting probabilistic beyond a few days?",
     "Ensemble forecasting"),
    ("How does desalination remove salt from seawater?",
     "Desalination"),
    ("Why do legumes enrich soil with nitrogen?",
     "Nitrogen fixation"),
    ("What makes a sourdough starter rise without commercial yeast?",
     "Sourdough"),
    ("How does mass spectrometry separate ions by mass?",
     "Mass spectrometry"),
    ("How does PCR amplify a specific DNA sequence?",
     "Polymerase chain reaction"),
    ("Why does the Haber process need high pressure?",
     "Haber process"),
    ("How does a catalyst speed a reaction without being consumed?",
     "Catalysis"),
    ("What is the difference between lidar and radar?",
     "Lidar"),
    ("How does an inertial navigation system drift over time?",
     "Inertial navigation system"),
    ("Why does GPS need four satellites rather than three?",
     "Global Positioning System"),
    ("How does negative feedback stabilise a control loop?",
     "Control theory"),
    ("How does a convolutional network exploit translation invariance?",
     "Convolutional neural network"),
    ("Why does reinforcement learning need exploration?",
     "Reinforcement learning"),
    ("How does a Monte Carlo estimate converge with sample count?",
     "Monte Carlo method"),
    ("What does the ACID acronym guarantee for a transaction?",
     "ACID"),
    ("How does write ahead logging make a database crash safe?",
     "Write-ahead logging"),
]


def rank_documents(db: sqlite3.Connection, question: str, limit: int = 64, keep: int = 3):
    ts = terms(question)
    strategy = "none"
    rows = []
    for name, expr in strategies(ts):
        rows = db.execute(
            """
            SELECT c.doc_id, d.title, bm25(chunks_fts) AS rank
            FROM chunks_fts
            JOIN chunks c ON c.id = chunks_fts.rowid
            JOIN docs d ON d.id = c.doc_id
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """,
            (expr, limit),
        ).fetchall()
        if rows:
            strategy = name
            break

    best: dict[int, tuple[float, str]] = {}
    for doc_id, title, rank in rows:
        score = -rank
        if doc_id not in best or score > best[doc_id][0]:
            best[doc_id] = (score, title)
    ordered = sorted(best.items(), key=lambda kv: -kv[1][0])
    return strategy, [(doc_id, title, score) for doc_id, (score, title) in ordered[:keep]], len(rows)


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=os.path.join(root, "App", "Resources", "corpus.sqlite"))
    ap.add_argument("--json", default="")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.db):
        print(f"missing index: {args.db}\nrun Scripts/build_index.py first", file=sys.stderr)
        return 2

    db = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    titles = {row[0] for row in db.execute("SELECT title FROM docs")}

    results = []
    started = time.time()
    for question, expected in EVAL_SET:
        if expected not in titles:
            results.append({"question": question, "expected": expected, "status": "skipped-missing-doc"})
            continue
        strategy, docs, candidates = rank_documents(db, question)
        names = [t for _, t, _ in docs]
        rank = names.index(expected) + 1 if expected in names else 0
        results.append(
            {
                "question": question,
                "expected": expected,
                "strategy": strategy,
                "candidates": candidates,
                "top3": names,
                "rank": rank,
                "hit@1": rank == 1,
                "hit@3": rank >= 1,
                "rr": (1.0 / rank) if rank else 0.0,
            }
        )

    scored = [r for r in results if r.get("rank") is not None and "rank" in r]
    n = len(scored)
    summary = {
        "questions": len(EVAL_SET),
        "scored": n,
        "skipped_missing_doc": len(results) - n,
        "hit@1": round(sum(1 for r in scored if r["rank"] == 1) / n, 4) if n else 0,
        "hit@3": round(sum(1 for r in scored if r["rank"] >= 1) / n, 4) if n else 0,
        "mrr": round(sum(r["rr"] for r in scored) / n, 4) if n else 0,
        "mean_candidates": round(sum(r["candidates"] for r in scored) / n, 1) if n else 0,
        "elapsed_s": round(time.time() - started, 3),
        "index": os.path.relpath(args.db, root),
    }

    print(json.dumps(summary, indent=2))
    misses = [r for r in scored if r["rank"] == 0]
    if misses:
        print(f"\nmisses ({len(misses)}):")
        for r in misses:
            print(f"  Q: {r['question']}\n     want={r['expected']!r} got={r['top3']}")
    if args.verbose:
        print("\nper-question:")
        for r in scored:
            mark = "ok " if r["rank"] else "MISS"
            print(f"  [{mark}] r={r['rank']} {r['strategy']:<11} {r['question'][:70]}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"summary": summary, "results": results}, fh, indent=2)
            fh.write("\n")
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
