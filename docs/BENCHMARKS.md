# Benchmark plan

The bounty's bar is usefulness for real lookups, not a leaderboard. This plan is built so
that someone else can reproduce it and disagree with the numbers.

## 1. Retrieval (runs anywhere, no model)

Committed: `Scripts/eval_retrieval.py` (`make eval`).

- 53 questions, each with one expected article, phrased the way a person asks rather than
  the way the article is titled.
- Metrics: hit@1, hit@3 (the documents actually sent to the prompt), MRR, mean candidate
  count, latency.
- Baseline recorded in `README.md`. **Any change to chunking, query planning or the
  reranker must re-run this and keep hit@3 ≥ 0.90**, otherwise the change is a regression
  even if answers "look better".

Extension: grow to 150 questions across the corpus's subject areas before growing the
corpus, so recall changes are measurable rather than vibes.

## 2. Generation quality (needs a model)

40 question/answer pairs in three buckets:

- **factual (15)** — the answer is stated in one passage. Tests retrieval + faithful
  quoting.
- **synthesis (15)** — the answer requires combining two or more passages (compare X and
  Y, what do these have in common). This is where a 1.5B model earns or loses its place.
- **reasoning (10)** — the answer is not stated anywhere in the corpus and must be derived
  from it. Marked `(general knowledge)` or admitted as unknown; both are acceptable,
  a confident wrong answer is not.

Scoring, done blind:

- the runner records answers with the model identity stripped and order shuffled;
- a second model scores each answer 0–3 against a written reference answer that includes
  the required citation numbers:
  - 3 = correct and cited; 2 = correct but uncited or over-cited; 1 = partially correct;
    0 = wrong, or claims a citation that does not support the sentence;
- report per-bucket means and the share of answers with at least one fabricated citation.
  A fabricated citation is an automatic 0 for that item regardless of the text.

Baselines to report side by side: `ExtractiveEngine` (no model), Qwen2.5-0.5B Q4_K_M,
Qwen2.5-1.5B Q4_K_M. The published claim should be the delta over extractive, because
that delta is what the model is actually contributing.

## 3. Device performance (needs hardware)

Protocol, per model profile, on at least one recent iPhone and one 4 GB device:

1. Cold start: launch with the model unloaded, measure time to first token for a fixed
   question (three runs, report median).
2. Throughput: 20 questions, `maxTokens = 512`, record tok/s from the message footer
   (the app logs `generated / elapsed_since_first_token`).
3. Memory: Xcode memory gauge peak during a 512-token answer, plus
   `os_proc_available_memory` before load. Compare to the estimate in `models.json`
   (`estimatedResidentMB`), which is weights + KV + 220 MB overhead.
4. Thermal: 5 minutes of continuous queries, record `ProcessInfo.thermalState`
   transitions and the tok/s drop between minute 1 and minute 5.
5. Context scaling: same question at 2048 / 4096 / 8192 context; report tok/s and peak
   memory. This is the number that decides whether 8192 is a setting or a trap.

Report as a table per device × model. Numbers must come from a device; they are not
extrapolated from desktop CPU benchmarks.

## 4. Offline verification (needs hardware, is the actual bounty requirement)

1. Install the app, install a model, then enable Airplane Mode and disable Wi-Fi.
2. Run the 40-question generation suite and the 53-question retrieval suite manually.
3. Check *Settings → Diagnostics → Offline attempts blocked* is 0.
4. Capture a screen recording of a full question/answer cycle with the status bar showing
   no connectivity, and the diagnostics screen before and after.
5. Optionally run with the device tethered to a proxy on the Mac and confirm zero
   requests appear in the proxy log while the counter stays 0.

Step 5 is the strongest evidence and the one to lead with: a proxy log with no entries
during a full session, plus an app whose source contains no network API at all.
