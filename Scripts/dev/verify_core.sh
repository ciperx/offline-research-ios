#!/usr/bin/env bash
# Verify the Swift sources without a Mac.
#
#   1. `swiftc -parse` on every Swift file  -> syntax errors, unbalanced #if, etc.
#   2. `swiftc -typecheck` on the platform-neutral core (retrieval + engines + models)
#      -> real type resolution, protocol conformance, misuse of the llama-free layer
#   3. compile + run Scripts/dev/RetrievalSmoke against App/Resources/corpus.sqlite
#      -> the retriever actually returns the expected documents
#
# SwiftUI/UIKit files (App/Sources/UI, AppModel, App entry) cannot be type-checked off
# Darwin: they are parse-checked only. That limitation is stated in docs/VERIFICATION.md.
#
# Requires: swiftc on PATH (Xcode, or a Linux toolchain from swift.org).
#   Linux also needs libsqlite3.so available to the linker; if only
#   libsqlite3.so.0 exists, the script symlinks it into .build/devlib.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
DEV="$ROOT/Scripts/dev"
OUT="$ROOT/.build/dev"
mkdir -p "$OUT/lib"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found — install Xcode, or a Swift toolchain from https://swift.org/download"
  exit 3
fi

echo "swiftc: $(swiftc --version | head -1)"

# Linker convenience: provide an unversioned libsqlite3.so if the dev package is absent.
if [ ! -e "$OUT/lib/libsqlite3.so" ]; then
  for candidate in /usr/lib/x86_64-linux-gnu/libsqlite3.so /usr/lib/aarch64-linux-gnu/libsqlite3.so /usr/lib/libsqlite3.so; do
    [ -e "$candidate" ] && ln -sf "$candidate" "$OUT/lib/libsqlite3.so" && break
  done
  if [ ! -e "$OUT/lib/libsqlite3.so" ]; then
    versioned=$(ls /usr/lib/*/libsqlite3.so.0 2>/dev/null | head -1 || true)
    [ -n "$versioned" ] && ln -sf "$versioned" "$OUT/lib/libsqlite3.so"
  fi
fi

fail=0

echo
echo "== 1/3 swiftc -parse (all Swift files)"
mapfile -t all_swift < <(find App/Sources Tests -name '*.swift' | sort)
echo "   ${#all_swift[@]} files"
if ! swiftc -parse "${all_swift[@]}" 2> "$OUT/parse.log"; then
  echo "   PARSE FAILED:"; sed -n '1,40p' "$OUT/parse.log"; fail=1
else
  echo "   ok"
fi

echo
echo "== 2/3 swiftc -typecheck (platform-neutral core)"
CORE=(
  App/Sources/Support/AppLog.swift
  App/Sources/Support/TextUtil.swift
  App/Sources/Support/UTF8StreamDecoder.swift
  App/Sources/Support/SHA256.swift
  App/Sources/Retrieval/QueryTerms.swift
  App/Sources/Retrieval/CorpusStore.swift
  App/Sources/Retrieval/PassageReranking.swift
  App/Sources/Retrieval/RetrievalService.swift
  App/Sources/Retrieval/ExtractiveComposer.swift
  App/Sources/Engine/LLMEngine.swift
  App/Sources/Engine/PromptBuilder.swift
  App/Sources/Engine/ExtractiveEngine.swift
  App/Sources/Model/ModelProfile.swift
)
if ! swiftc -typecheck -I "$DEV/SQLite3" -L "$OUT/lib" "${CORE[@]}" 2> "$OUT/typecheck.log"; then
  echo "   TYPECHECK FAILED:"; sed -n '1,60p' "$OUT/typecheck.log"; fail=1
else
  echo "   ok (${#CORE[@]} files)"
fi

echo
echo "== 3/3 retrieval smoke test (real corpus)"
CORPUS="${1:-$ROOT/App/Resources/corpus.sqlite}"
if [ ! -f "$CORPUS" ]; then
  echo "   skipped: $CORPUS missing (run 'make corpus && make index')"
else
  if swiftc -O -I "$DEV/SQLite3" -L "$OUT/lib" \
      "${CORE[@]}" "$DEV/RetrievalSmoke/main.swift" -o "$OUT/retrieval-smoke" 2> "$OUT/smoke-build.log"; then
    "$OUT/retrieval-smoke" "$CORPUS" || fail=1
  else
    echo "   BUILD FAILED:"; sed -n '1,40p' "$OUT/smoke-build.log"; fail=1
  fi
fi

echo
if [ "$fail" -eq 0 ]; then echo "verify_core: PASS"; else echo "verify_core: FAIL"; fi
exit "$fail"
