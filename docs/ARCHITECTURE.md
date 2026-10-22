# Architecture notes

Deeper rationale for the choices in `README.md`. Read that first for the shape; this file
is the "why, and what was rejected".

## Layers

```
UI (SwiftUI, @MainActor)
  ChatView · MessageBubble · ComposerView · SettingsView · SourcesSheet
        │  bindings + intents
AppModel (@MainActor ObservableObject)
  conversation state, settings persistence, engine lifecycle, retrieval → prompt → stream
        │
        ├── RetrievalService (pure Swift, no UI, no engine)
        │     QueryTerms → CorpusStore.search → rerank → per-document dedupe
        ├── PromptBuilder (pure Swift)
        │     numbered sources, token budget, stop-sequence trimming
        └── LLMEngine (protocol)
              ExtractiveEngine ── RetrievalService + ExtractiveComposer
              LlamaEngine ─────── llama.cpp C API (bridging header)
```

Everything except `UI`, `AppModel` and `LlamaEngine` is platform-neutral Swift with no
Apple-only frameworks, which is what makes `Scripts/dev/verify_core.sh` able to
type-check it and *run* the retriever on Linux.

## Retrieval pipeline

**Query plan.** `QueryTerms` produces up to four FTS5 expressions, tried in order until
one returns hits: `AND` + prefix, `AND`, `OR` + prefix, `OR`. The AND-first order is what
keeps precision high on multi-term questions; the OR fallback is what prevents a single
unknown word ("quantisation") from returning nothing. All terms are double-quoted with
internal quotes doubled, so user input cannot inject FTS5 syntax.

**Scoring.** SQLite's `bm25()` returns negative values (more negative = better); the
service negates it. Raw BM25 is normalised by the best candidate before blending, so the
blend is stable across queries with very different score magnitudes.

**Why a second stage at all.** BM25 rewards rare terms wherever they appear. A question
like "compare RSA and elliptic-curve cryptography" ranks pages that mention both words
once above a page that actually explains the trade-off. The lexical reranker measures
*coverage* (weighted, with title bonus and a full-coverage bonus), which correlates much
better with "this passage answers the question".

**Per-document dedupe.** Ranking chunks directly lets one long article supply the top
five results. The service keeps the best chunk per document, then fills second chunks only
after each chosen document has one. With `documentsToKeep = 3` this yields at most six
passages across three articles — the diversity a comparison question needs.

**Empty and unknown queries.** A stopword-only question returns `strategy: "empty"` and no
passages rather than scanning the corpus. A question with no FTS hits falls back to a
title substring lookup, then gives up — and the prompt tells the model that no sources
were retrieved, which is the honest state.

## Prompt construction

`PromptBuilder` budgets by *estimated* tokens (chars/4) and enforces the budget before the
prompt reaches the model:

- history is capped first (newest turns kept, oldest dropped);
- sources are added until the source character budget is spent, then trimmed per-passage;
- if the assembled prompt still exceeds `maxPromptTokens`, sources are dropped from the
  tail until it fits.

The last step matters: llama.cpp silently keeps the *head* of an over-long prompt, which
would discard the question and the best passages. Dropping whole sources from the tail is
visible in the prompt and degrades predictably.

The system prompt asks for inline `[n]` citations and for out-of-corpus claims to be
marked `(general knowledge)`. That convention is what the UI's citation row and the
extractive mode both follow, so an answer's provenance is legible whichever engine
produced it.

## Engines

`LLMEngine` is a small protocol: `load`, `stream(turns:sampling:)`, `cancel`, `unload`,
plus `stats`. Streaming is `AsyncThrowingStream<EngineEvent, Error>` with `.token` and a
terminal `.stats`.

`LlamaEngine` details that are easy to get wrong and are handled explicitly:

- **Positions** — `llama_batch_get_one` lets the context track positions; the engine
  prefills in `n_batch`-sized slices and then decodes one token at a time.
- **Sampler per request** — the chain (top-k → top-p → min-p → temp → dist) is built and
  freed per generation, so temperature changes do not require a reload.
- **Chat template** — `llama_chat_apply_template(nil, …)` uses the template stored in the
  GGUF; if that returns ≤ 0 the engine falls back to ChatML, which is what both catalog
  families (Qwen2.5, SmolLM2) use.
- **UTF-8** — a token can end mid-scalar. `UTF8StreamDecoder` buffers incomplete trailing
  bytes and emits only complete scalars, so CJK and emoji stream correctly.
- **Stop conditions** — EOG token, max tokens, context exhaustion, or a matched stop
  string; each is reported in the stats/log so a truncated answer is explainable.
- **Cancellation** — a flag checked between tokens, surfaced as `EngineError.cancelled`.

`ExtractiveEngine` runs the same retrieval, then `ExtractiveComposer` scores every
sentence of the retrieved passages by term coverage, length and position, and selects up to
six with maximal-marginal-relevance (λ = 0.72) to avoid repeating the same sentence in
different words. Output is a quoted answer with `[n]` markers and a source list.

## Offline enforcement

A claim of "no network" is worth exactly as much as its enforcement mechanism.

1. `Scripts/check_offline.sh` greps all of `App/Sources` for 17 forbidden symbols
   (`URLSession`, `Network`, `WebKit`, `CFStream`, `CloudKit`, `getaddrinfo`, …) with
   `Safety/OfflineGuard.swift` as the single allow-listed file, and fails CI on a hit.
   It also checks that `Info.plist` does not set `NSAllowsArbitraryLoads = true`.
2. `OfflineGuard.install()` registers a `URLProtocol` early in `@main`; `canInit` returns
   true only for `http`/`https`/`ws`/`wss`/`ftp`, and every such load fails immediately
   with `NSURLErrorNotConnectedToInternet` (code -1009) plus a log line.
3. Refusals increment a counter surfaced in Settings → Diagnostics, so the guarantee is
   observable at runtime instead of asserted in a doc.

## Rejected alternatives

- **SwiftPM dependency on llama.cpp.** Upstream's package surface changes between tags;
  pinning a tag and building one static library with an explicit script is more
  reproducible than betting on a package manifest, and it keeps `-DNO_LLAMA_ENGINE`
  possible (no package resolution to fight).
- **A vector database (sqlite-vec, USearch).** For ~10³ chunks, brute-force cosine over
  on-device embeddings is fine, but it adds a dependency, a second index file and a
  materialisation step for zero measured recall benefit at this corpus size. The lexical
  reranker is the 80% version; `HybridReranker` keeps the door open.
- **Bundling the model in the app.** 1.1 GB in the repo, unbuildable for most people.
  Fetch-then-import with a pinned SHA-256 keeps the clone small and the weight reproducible.
- **A server-rendered "demo".** The bounty is about the phone being offline; a web demo
  would be a different, easier, less honest thing.
