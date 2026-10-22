# Offline Research — iOS

A research assistant that runs **entirely on the phone**. No network code, no API keys,
no accounts. A bundled retrieval index plus an optional on-device GGUF model answer
questions about mechanisms, comparisons and numbers, and cite the passages they used.

Built for the *offline research app* bounty ([poidh base#1405](https://poidh.xyz/base/bounty/1405)),
whose bar is: run fully offline, be genuinely useful for real lookups, and ship as a
reproducible public repo.

```
iOS 16+ · Swift 5 · SwiftUI · SQLite FTS5 · llama.cpp (GGUF) · no network
```

---

## What it does

Two modes, same UI, switchable in Settings:

| Mode | What runs | When |
|---|---|---|
| **Retrieval only** | FTS5 + BM25 + on-device rerank, then extractive composition (MMR sentence selection) | Always works. No model installed, no native library needed. |
| **Local model** | The same retrieved passages go into a prompt for a GGUF model via llama.cpp | After a model file is installed |

Answers carry `[1] [2]` citations. Tapping them shows the article title, source URL and
the exact excerpt used, so a claim can always be traced to a passage.

**Retrieval only is not a stub.** It is the floor the model has to beat: measured on 53
hand-written questions against the shipped index it puts the right article in the top 3
documents 92.5% of the time (see [Measured numbers](#measured-numbers)). On a device with
no model, that is a working research tool — just a quoting one rather than a synthesising
one.

---

## Architecture

```
┌──────────────────────────── App (SwiftUI, iOS 16) ────────────────────────────┐
│                                                                              │
│  ChatView ── AppModel ──┬── RetrievalService ── CorpusStore ── corpus.sqlite  │
│                         │        │                    (FTS5, bundled, RO)    │
│                         │        ├── QueryTerms      query plan: AND→OR,      │
│                         │        │                   prefix, stopwords       │
│                         │        ├── bm25()         SQLite FTS5 ranking      │
│                         │        └── Reranker       lexical / NLEmbedding    │
│                         │                                                    │
│                         ├── PromptBuilder    numbered sources + budget trim  │
│                         │                                                    │
│                         └── LLMEngine (protocol)                             │
│                              ├── ExtractiveEngine   no model, always present │
│                              └── LlamaEngine        llama.cpp C API, GGUF    │
│                                                                              │
│  OfflineGuard ── URLProtocol that fails every http(s) load, counted in UI     │
└──────────────────────────────────────────────────────────────────────────────┘
```

Request path for one question:

1. `QueryTerms` normalises the question: lowercase, plural fold, stopword and
   question-word removal (so "how does X work" leaves `x`), then builds progressively
   looser FTS5 plans — `AND` with prefix matching, `AND`, `OR` with prefix, `OR`.
   Every term is quoted, so a `"` or `*` in a question can never become FTS5 syntax.
2. `CorpusStore.search` runs the plan against `chunks_fts` ordered by `bm25()`.
3. `RetrievalService` keeps the best chunk per document, re-scores with a lexical
   reranker (term coverage, title bonus, full-coverage bonus) blended 65/35 with
   normalised BM25, then takes the top *N* documents and up to 2 chunks each — so one
   keyword-rich article cannot crowd out the comparison the user asked for.
4. `PromptBuilder` numbers the passages, trims them to the context budget, and appends
   the question. The system prompt tells the model to cite sources, mark anything
   outside them as general knowledge, and admit when the corpus does not answer.
5. The engine streams tokens; `UTF8StreamDecoder` reassembles multi-byte characters
   that llama.cpp splits across tokens, so CJK and emoji do not become mojibake.

### Why these choices

**SQLite FTS5, not a vector store.** A phone-sized corpus (10⁵–10⁶ chunks) does not need
an ANN index; BM25 over FTS5 is exact, tiny (the whole 4.3 MB index ships in the bundle),
and updates in microseconds. The reranker adds the semantic nudge that pure BM25 lacks,
using Apple's on-device sentence embeddings when available and lexical coverage otherwise.

**Extractive mode as a first-class engine, not a fallback error.** It makes the app
useful before any download, and it gives the benchmark a baseline that is honest — a
model that cannot beat "quote the three best passages" is not adding value.

**A protocol between the app and llama.cpp.** `LLMEngine` has two implementations, so
the UI, prompt builder and retriever are all testable without a 1.1 GB weight file, and
the llama.cpp layer can be compiled out entirely (`NO_LLAMA_ENGINE`) for a
retrieval-only build.

---

## Reproduce on macOS

Requirements: Xcode 15+, XcodeGen, CMake (`brew install xcodegen cmake`). An Apple
Silicon Mac is assumed for the simulator; the device build is arm64.

```bash
git clone https://github.com/ciperx/offline-research-ios
cd offline-research-ios

make doctor          # report missing tools and artefacts
make llama           # clone llama.cpp v0.7.0, build static libs (device + simulator)
make project         # xcodegen generate  ->  OfflineResearch.xcodeproj
make model           # download + verify the default GGUF into Models/  (~1.1 GB)
make open            # open in Xcode
```

Then, in Xcode: pick your team under *Signing & Capabilities*, select a device or the
simulator, Run.

**First launch with no model:** the app opens in *Retrieval only* mode and answers
immediately — no setup, no warning wall. To enable the model, in the running app:
*Settings → Add model file…* and pick the `.gguf` from `Models/`. It is checksum-verified
against `App/Resources/models.json` on import (the same SHA-256 the download script
verified), copied into Application Support, and excluded from iCloud backup.

Faster path with no native build at all:

```bash
make project-nollama   # retrieval-only project, no cmake, no llama.cpp
```

That configuration compiles out `LlamaEngine` and the `#include "llama.h"` in the
bridging header, so the app builds and runs with only Xcode + XcodeGen.

### Model without re-running the script

`Models/` is gitignored. Any single-file GGUF works, not just the catalog: drop it into
the app's Documents folder over Finder file sharing (`UIFileSharingEnabled` is on) or use
*Add model file…*. Catalog entries get checksum verification; arbitrary files get a
warning instead of a hard failure.

---

## What is verified, and what is not

This project was assembled on a **Linux box with no Xcode and no iOS device**. Being
precise about that matters more than a green checkmark:

**Actually executed and passing**

- `python3 Scripts/eval_retrieval.py` — 53 questions against the shipped index:
  hit@1 0.849, hit@3 0.925, MRR 0.881, 0.109 s total (see `docs/retrieval_eval.json`).
- `python3 Scripts/build_index.py` — rebuilt `App/Resources/corpus.sqlite` from
  `Corpus/raw/wiki.jsonl`: 115 articles, 1,031 chunks, `PRAGMA quick_check` = ok,
  4,333,568 bytes, sha256 `0c832320d1f2…`.
- `python3 Scripts/fetch_corpus.py` — the corpus in this repo was produced by it
  (216,286 words, 115 articles, manifest with per-file SHA-256).
- `swiftc -parse` and `swiftc -typecheck` — see `docs/VERIFICATION.md`; the platform-neutral
  core (retrieval, prompt building, extractive engine, model catalog, SHA-256, UTF-8
  decoder) is type-checked with Swift 6, and the retriever is *executed* against the real
  corpus by `Scripts/dev/RetrievalSmoke/main.swift`.
- `bash Scripts/verify_repo.sh` — JSON, YAML, plist, SQLite, shell syntax, Python
  compile, offline deny-list, catalog consistency: all green.
- `bash Scripts/check_offline.sh` — 0 network APIs across all Swift sources.

**Not executed anywhere, and flagged as such**

- **No Xcode build, no archive, no App Store/TestFlight upload, no run on a physical
  iPhone or in a simulator.** Xcode does not exist on Linux. `xcodegen generate` was not
  run either (XcodeGen is macOS-only), so `project.yml` is validated as YAML and by a
  scripted structural check, not by generating a project.
- **llama.cpp was not compiled here.** `Scripts/build_llama.sh` is written against the
  real `include/llama.h` from tag `v0.7.0` (every function signature used in
  `LlamaEngine.swift` was read from that file), and the CMake flags follow upstream's own
  iOS guidance, but the script itself has not been run — no Xcode toolchain to run it with.
- **Token throughput, memory and thermals on real hardware are unmeasured.** The
  1,900 MB figure for the 1.5B Q4_K_M profile is an estimate (weights + KV + overhead),
  not a measurement. `docs/BENCHMARKS.md` contains the protocol to produce real numbers,
  and the app already displays tok/s, first-token latency and token counts per answer so
  the measurement is one screenshot away.

---

## Measured numbers

Retrieval, 53 questions, shipped index, `Scripts/eval_retrieval.py`:

```
hit@1 0.8491   hit@3 0.9245   MRR 0.8805
mean candidate chunks 57.4   total time 0.109 s
```

The four misses are instructive rather than embarrassing, and are left in the harness as
known limitations:

- *"positive test … probability of disease"* → missed **Bayesian inference** (the article
  says "base rate"; the question says "positive test").
- *"quantisation lose information"* → missed **Quantization** — British spelling is not
  normalised to the article's American title. One-line fix, deliberately not hidden.
- *"time passes differently at different altitudes"* → missed **General relativity**
  (paraphrase with no shared surface term).
- *"legumes … nitrogen"* → picked **Crop rotation** over **Nitrogen fixation** — the
  broader article genuinely covers the term.

These are the cases a semantic reranker or a bigger corpus should fix; the harness is
committed so the claim can be checked rather than believed.

Index: 115 articles / 1,031 chunks / 4.33 MB / integrity ok.

---

## Repository layout

```
project.yml                  XcodeGen spec: app + test targets, 4 build configs
Configs/WithLlama.xcconfig   links vendor/llama static libs per SDK
Configs/NoLlama.xcconfig     -DNO_LLAMA_ENGINE, retrieval-only build
App/
  Info.plist                 ATS locked down, file sharing on, no network keys
  Bridging/…-Header.h        the only C interop: #include "llama.h"
  Sources/
    OfflineResearchApp.swift  @main, installs OfflineGuard before any view
    AppModel.swift            @MainActor state: retrieval → prompt → stream
    Engine/                   LLMEngine protocol, LlamaEngine, ExtractiveEngine,
                              PromptBuilder, sampling/engine config
    Retrieval/                QueryTerms, CorpusStore (FTS5), RetrievalService,
                              rerankers, ExtractiveComposer
    Model/                    catalog decoding, model install/verify/delete
    Safety/OfflineGuard.swift URLProtocol block + audit counter
    Support/                  SHA-256, UTF-8 stream decoder, text utils, logging
    UI/                       chat, message bubbles, composer, settings, sources
  Resources/
    corpus.sqlite            the only data asset (4.3 MB, FTS5)
    models.json              catalog: url + sha256 + context + RAM estimate
Corpus/
  topics.txt                 the 375 candidate article titles
  raw/wiki.jsonl             the fetched corpus, with per-article license + URL
  raw/manifest.json          provenance + SHA-256 of the corpus file
Scripts/
  fetch_corpus.py            build-time network fetch (the only network code anywhere)
  build_index.py             chunker + FTS5 index builder
  eval_retrieval.py          retrieval metrics (mirrors the Swift query plan)
  build_llama.sh             llama.cpp v0.7.0 → static libs for device + simulator
  fetch_model.sh             download + SHA-256 verify a catalog GGUF
  check_offline.sh           fails if a network API appears in App/Sources
  verify_repo.sh             JSON/YAML/plist/SQLite/shell/offline checks
  doctor.sh                  toolchain report
  dev/verify_core.sh         swiftc -parse + -typecheck + retrieval smoke test
  dev/RetrievalSmoke/        the smoke test that runs without Xcode
Tests/                       XCTest: retrieval, prompt budget, UTF-8, SHA-256,
                             query plan, offline guard, model catalog
docs/                        ARCHITECTURE, BENCHMARKS, VERIFICATION, eval output
```

---

## Offline guarantee

Three layers, all checkable:

1. **No networking code.** `App/Sources` contains no `URLSession`, `Network`,
   `WebKit`, `CFStream`, `CloudKit` or socket reference; `Scripts/check_offline.sh`
   enforces it and fails the build if one appears. The only network code in the repo is
   `Scripts/fetch_corpus.py` and `Scripts/fetch_model.sh`, which run at *build* time on a
   Mac and are never part of the app.
2. **Runtime block.** `OfflineGuard` registers a `URLProtocol` that fails every
   `http`/`https`/`ws`/`wss` load, so even a dependency that tried to reach the network
   could not. `file://` and `data:` loads still work (bundle resources, the SQLite corpus).
3. **Observable audit.** Every refused load increments a counter shown in
   *Settings → Diagnostics → Offline attempts blocked*, which should read 0. Test it:
   put the device in Airplane Mode, use the app for a while, check the counter and the
   console. The app has no code path that can make it move.

`App/Info.plist` sets `NSAllowsArbitraryLoads = false` and declares no networking
entitlements.

---

## Benchmark plan

Full protocol in [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md). Summary:

- **Retrieval** — committed harness, 53 questions, hit@1/hit@3/MRR, plus latency. Runs
  anywhere: `make eval`. Extend the question set before extending the corpus.
- **Generation** — 40 question/answer pairs in three buckets: factual (single passage),
  synthesis (two or more passages must be combined), and reasoning (the answer is not
  stated anywhere and must be derived). Scored blind by a second model *after* the run,
  with a rubric that rewards correct, cited answers and penalises uncited claims.
- **Device** — tok/s, first-token latency, peak memory (`Xcode memory gauge` +
  `os_proc_available_memory`), and thermal state after 5 minutes of continuous queries,
  on at least one recent iPhone and one older device. The app already reports tok/s and
  first-token latency per answer in the message footer; the benchmark is a scripted
  version of what the UI shows.
- **Offline** — the whole suite runs once in Airplane Mode with the network stack
  verified idle, and the `OfflineGuard` counter is checked to be 0 afterwards.

---

## Limits, honestly

- The bundled corpus is **115 articles (~216k words)** — enough to demonstrate the
  retrieval and prompting path, not enough to be a general knowledge base. `make corpus`
  extends it to any topic list; the index rebuilds in about a second.
- **CPU inference only** in the default build. `Scripts/build_llama.sh` builds Metal by
  default (`GGML_METAL=ON`, embedded metallib) but no Metal path has been exercised here;
  `make llama-cpu` is the conservative option.
- A 1.5B Q4 model is a **competent summariser and a weak reasoner**. The honest pitch is
  "a fast offline lookup and explanation tool that cites its sources", not "a frontier
  model in your pocket".
- Not built, not signed, not run on a device — see [What is verified](#what-is-verified-and-what-is-not).

---

## License

Code: MIT (see `LICENSE`). Corpus text: CC BY-SA 4.0 with per-article attribution in
`ATTRIBUTION.md`. Model weights: not distributed here; each catalog entry links to its
own license (Apache-2.0 for Qwen2.5 and SmolLM2). llama.cpp: MIT, fetched at build time.
