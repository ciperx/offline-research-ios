#!/usr/bin/env bash
# Report what the local machine can and cannot do, before anything is built.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
missing=0

check() { # check <label> <command> <hint> [required]
  local label="$1" cmd="$2" hint="${3:-}" required="${4:-required}"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  ok      %-12s %s\n" "$label" "$(command -v "$cmd")"
  else
    printf "  %-7s %-12s %s\n" "$([ "$required" = required ] && echo MISSING || echo note)" "$label" "$hint"
    [ "$required" = required ] && missing=1
  fi
}

echo "required:"
check xcodebuild xcodebuild "install Xcode from the App Store"
check xcrun xcrun "install Xcode command line tools"
check cmake cmake "brew install cmake"
check git git "xcode-select --install"
check xcodegen xcodegen "brew install xcodegen"
check python3 python3 "brew install python3"

echo
echo "optional:"
check jq jq "brew install jq (only for ad-hoc JSON poking)" optional
check swift swift "for Scripts/dev/verify_core.sh on Linux/macOS" optional

echo
if [ -d "$ROOT/vendor/llama/lib" ]; then
  echo "native libs: present ($(ls "$ROOT/vendor/llama/lib"))"
else
  echo "native libs: absent — run 'make llama' (or 'make project-nollama' for retrieval-only)"
fi
if [ -f "$ROOT/App/Resources/corpus.sqlite" ]; then
  echo "corpus index: present ($(du -h "$ROOT/App/Resources/corpus.sqlite" | cut -f1))"
else
  echo "corpus index: absent — run 'make corpus && make index'"
fi
if [ -d "$ROOT/Models" ] && compgen -G "$ROOT/Models/*.gguf" >/dev/null; then
  echo "models: $(ls "$ROOT/Models"/*.gguf | wc -l | tr -d ' ') file(s) in Models/"
else
  echo "models: none in Models/ — run 'make model'"
fi

echo
if [ "$missing" -eq 1 ]; then
  echo "some required tools are missing"
  exit 1
fi
echo "toolchain looks complete"
