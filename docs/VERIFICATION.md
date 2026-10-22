# Verification log

What was actually run, on what, and what it returned. Assembled on Linux (Debian 13,
x86_64, no Xcode, no iOS device) — so this file is deliberately split into "executed" and
"cannot be executed here".

## Environment

- Linux 6.8 x86_64, 2 vCPU, no Xcode, no macOS.
- Swift 6.0.3 (swift.org Linux toolchain) for `-parse`/`-typecheck` and the smoke test.
- Python 3.13, SQLite 3.46 (FTS5 enabled).

## Executed

### Corpus build

```
$ python3 Scripts/fetch_corpus.py --limit 200
  ... 115 articles fetched, 81 skipped (HTTP 429 from the API after ~60 requests;
      retries are bounded, so the run completes with a smaller corpus)
$ cat Corpus/raw/manifest.json | jq '.articles, .characters, .approx_words'
115
1297721
216286
```

The fetch is build-time only and is not part of the app. 81 skipped topics are recorded
in `Corpus/raw/manifest.json → skipped`, with the reason for each.

### Index build

```
$ python3 Scripts/build_index.py
{
  "docs": 115,
  "chunks": 1031,
  "fts_rows": 1031,
  "bytes": 4333568,
  "sha256": "0c832320d1f22dcfefd4aa36f223b25b1a06fdab3363a7c54078476bb7806e9a",
  "integrity": "ok"
}
```

`PRAGMA quick_check` = ok, FTS row count == chunk count, no orphans.

### Retrieval evaluation

```
$ python3 Scripts/eval_retrieval.py --json docs/retrieval_eval.json
{
  "questions": 53,
  "scored": 53,
  "hit@1": 0.8491,
  "hit@3": 0.9245,
  "mrr": 0.8805,
  "mean_candidates": 57.4,
  "elapsed_s": 0.109
}
```

Four misses, listed in `README.md`; the per-question detail is in
`docs/retrieval_eval.json`.

### Repository checks

```
$ bash Scripts/verify_repo.sh
== JSON            ok (every .json parses)
== YAML            ok (project.yml: 2 targets, 4 configs)
== plists          ok (App/Info.plist)
== corpus index    ok (115 docs, 1031 chunks, quick_check=ok)
== model catalog   ok (4 profiles, checksums well-formed)
== shell scripts   ok (bash -n on all)
== python          ok (compileall)
== offline         ok (0 network APIs)
== script smokes   ok (--help / --list on all CLIs)
```

### Swift syntax and types

Run with the swift.org Linux toolchain (Swift 6.0.3). `libncurses.so.6` is absent on
Debian 13 (only the wide build ships), so the toolchain needs a symlink shim to start:

```bash
mkdir -p /tmp/swiftlibs
ln -sf /usr/lib/x86_64-linux-gnu/libncursesw.so.6 /tmp/swiftlibs/libncurses.so.6
export LD_LIBRARY_PATH=/tmp/swiftlibs
```

```
$ swiftc -parse $(find App/Sources Tests -name '*.swift')
(no output, exit 0)          -- 33 files, zero syntax diagnostics

$ swiftc -typecheck -I Scripts/dev/SQLite3 -L .build/dev/lib <13 core files>
exit 0, 4 warnings: "NSLock.lock() unavailable from asynchronous contexts;
use async-safe scoped locking instead; this is an error in the Swift 6 language mode"

$ swiftc -O ... Scripts/dev/RetrievalSmoke/main.swift -o .build/dev/retrieval-smoke
$ ./.build/dev/retrieval-smoke App/Resources/corpus.sqlite
corpus: 115 articles, 1031 chunks, integrity=ok, schema=3
  ok    article count > 50
  ok    chunk count > 200
  ok    quick_check ok
retrieval:
  ok  top=TCP congestion control   strategy=or-prefix  candidates=64  367.1ms
  ok  top=Kalman filter            strategy=or-prefix  candidates=64  218.5ms
  ok  top=Solar cell               strategy=or-prefix  candidates=64  293.0ms
  ok  top=Bloom filter             strategy=or-prefix  candidates=64  125.8ms
  ok  top=Delta-v                  strategy=or-prefix  candidates=64  124.4ms
  ok  top=Write-ahead logging      strategy=or-prefix  candidates=64   75.7ms
  6/6 questions retrieved the expected document
  ok    stopword-only query returns nothing
extractive answer (1047 chars, citations [1, 4])            ok
prompt: 2 turns, 6841 chars (~1711 tokens) — system first, question last, under budget
  ok    retrieval is deterministic
ALL CHECKS PASSED
```

Full transcript: `docs/smoke-output.txt`.

The four warnings are real and not hidden: `ExtractiveEngine` and `LlamaEngine` call
`NSLock` from async contexts, which is legal in Swift 5 language mode (what this project
sets via `SWIFT_VERSION: "5.0"`) and an error under Swift 6 mode. The fix is to move the
cancel flag behind a synchronous helper or convert the engines to actors.

The type-checked core is 13 files: `Support/*` (4), `Retrieval/*` (5),
`Engine/{LLMEngine, PromptBuilder, ExtractiveEngine}`, `Model/ModelProfile`. `CorpusStore`
type-checks against a minimal SQLite shim (`Scripts/dev/SQLite3Shim.sqlite3.h`) that
declares only the functions it calls; the iOS build uses the SDK's real `SQLite3` module.

`Scripts/dev/verify_core.sh` packages exactly these three steps (it was assembled from the
manual commands above, and requires `swiftc` plus a `libsqlite3.so` the linker can see).

## Not executed, and why

| Item | Status | Reason |
|---|---|---|
| `xcodegen generate` | not run | macOS-only tool |
| `xcodebuild` (device/simulator) | not run | no Xcode, no macOS |
| `Scripts/build_llama.sh` | not run | needs Xcode + cmake iOS SDK sysroot |
| `swiftc` on UI files (type-check) | not run | SwiftUI/UIKit unavailable on Linux (parse-checked only) |
| XCTest suite | not run | requires an iOS simulator or device |
| On-device tok/s, RAM, thermal | not measured | no device |
| App Store / TestFlight | not attempted | out of scope for the bounty |

`project.yml` is validated as YAML plus a structural assertion script
(`Scripts/verify_repo.sh`: app target exists, type is `application`, expected configs
present). It is *not* validated by generating a project.

`Scripts/build_llama.sh` calls only functions that exist in `include/llama.h` at tag
`v0.7.0`; the CMake flags mirror upstream's iOS guidance and `GGML_METAL_EMBED_LIBRARY`
avoids shipping a separate `.metallib`. That is a careful script, not a tested build.
