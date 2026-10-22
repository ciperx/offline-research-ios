#!/usr/bin/env bash
# Download a GGUF from the pinned catalog and verify its SHA-256.
#
#   ./Scripts/fetch_model.sh                 # default profile (Qwen2.5 1.5B Q4_K_M)
#   ./Scripts/fetch_model.sh <id>            # e.g. qwen2.5-0.5b-instruct-q4_k_m
#   ./Scripts/fetch_model.sh --list
#   ./Scripts/fetch_model.sh --check         # verify files already in Models/
#
# Models are NOT committed (see .gitignore): the repo stays small and the weight file
# is reproducible from url + sha256 in App/Resources/models.json, which the app also
# reads. Downloads go to Models/; drop that file into the app via Settings → Add model.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/App/Resources/models.json"
DEST="$ROOT/Models"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need curl
need python3

meta() { # meta <id|--default> <field>
  python3 - "$CATALOG" "$1" "$2" <<'PY'
import json, sys
path, wanted, field = sys.argv[1], sys.argv[2], sys.argv[3]
cat = json.load(open(path))
models = cat["models"]
if wanted == "--default":
    mid = cat["default_model"]
else:
    mid = wanted
for m in models:
    if m["id"] == mid:
        print(m[field]); raise SystemExit(0)
print(f"unknown model id: {mid}", file=sys.stderr); raise SystemExit(1)
PY
}

if [ "${1:-}" = "--list" ]; then
  python3 - "$CATALOG" <<'PY'
import json, sys
cat = json.load(open(sys.argv[1]))
print(f"default: {cat['default_model']}\n")
for m in cat["models"]:
    print(f"{m['id']:<36} {m['size_bytes']/1e9:5.2f} GB  {m['quantization']:<8} {m['display_name']}")
PY
  exit 0
fi

MODEL_ID="${1:---default}"
FILE="$(meta "$MODEL_ID" file)"
URL="$(meta "$MODEL_ID" url)"
SHA="$(meta "$MODEL_ID" sha256)"
SIZE="$(meta "$MODEL_ID" size_bytes)"
mkdir -p "$DEST"
TARGET="$DEST/$FILE"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

if [ "${1:-}" = "--check" ]; then
  rc=0
  while read -r f s; do
    if [ -f "$DEST/$f" ]; then
      got="$(sha256_of "$DEST/$f")"
      [ "$got" = "$s" ] && echo "ok    $f" || { echo "FAIL  $f ($got)"; rc=1; }
    else
      echo "absent $f"
    fi
  done < <(python3 -c "
import json,sys
c=json.load(open('$CATALOG'))
[print(m['file'], m['sha256']) for m in c['models']]")
  exit $rc
fi

echo "model:  $MODEL_ID"
echo "file:   $FILE"
echo "size:   $((SIZE / 1048576)) MB"
echo "sha256: $SHA"

if [ -f "$TARGET" ] && [ "$(sha256_of "$TARGET")" = "$SHA" ]; then
  echo "already present and verified: $TARGET"
  exit 0
fi

echo "downloading…"
curl -L --fail --retry 3 --retry-delay 2 -C - -o "$TARGET.part" "$URL"
ACTUAL="$(sha256_of "$TARGET.part")"
if [ "$ACTUAL" != "$SHA" ]; then
  echo "checksum mismatch" >&2
  echo "  expected $SHA" >&2
  echo "  actual   $ACTUAL" >&2
  rm -f "$TARGET.part"
  exit 1
fi
mv "$TARGET.part" "$TARGET"
echo "verified: $TARGET"
echo
echo "Next: in the app, Settings → Add model file… and pick $FILE"
echo "  (or copy it to the app's Documents folder over Finder file sharing)"
