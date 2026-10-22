#!/usr/bin/env bash
# Everything checkable without Xcode: JSON/YAML/plist validity, the SQLite index, shell
# syntax, Python byte-compilation, the offline deny-list, and the model catalog's
# internal consistency. `make verify` runs this.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
step() { printf "\n== %s\n" "$1"; }
ok()   { printf "   ok    %s\n" "$1"; }
bad()  { printf "   FAIL  %s\n" "$1"; fail=1; }

PY="${PYTHON:-python3}"

step "JSON"
while IFS= read -r f; do
  if "$PY" -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
    ok "$f"
  else
    bad "$f (invalid JSON)"
  fi
done < <(find . -name '*.json' -not -path './vendor/*' -not -path './.build/*' -not -path './Models/*' | sort)

step "YAML (project.yml)"
if "$PY" -c "import yaml" 2>/dev/null; then
  if "$PY" - <<'PY'
import sys, yaml
doc = yaml.safe_load(open("project.yml"))
assert isinstance(doc, dict), "project.yml is not a mapping"
assert "targets" in doc and "OfflineResearch" in doc["targets"], "missing app target"
assert doc["targets"]["OfflineResearch"]["type"] == "application"
print("   ok    project.yml (%d targets, %d configs)"
      % (len(doc["targets"]), len(doc.get("configs", {}))))
PY
  then : ; else bad "project.yml"; fi
else
  echo "   skip  PyYAML not installed (python3 -m venv && pip install pyyaml)"
fi

step "plists"
while IFS= read -r f; do
  if "$PY" -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$f" 2>/dev/null; then
    ok "$f"
  else
    bad "$f (invalid plist)"
  fi
done < <(find . -name '*.plist' -not -path './vendor/*' | sort)

step "corpus index"
if [ -f App/Resources/corpus.sqlite ]; then
  "$PY" - <<'PY'
import sqlite3
db = sqlite3.connect("file:App/Resources/corpus.sqlite?mode=ro", uri=True)
tables = {r[0] for r in db.execute("select name from sqlite_master where type in ('table','view')")}
need = {"meta", "docs", "chunks", "chunks_fts"}
missing = need - tables
assert not missing, f"missing tables: {missing}"
docs = db.execute("select count(*) from docs").fetchone()[0]
chunks = db.execute("select count(*) from chunks").fetchone()[0]
fts = db.execute("select count(*) from chunks_fts").fetchone()[0]
check = db.execute("pragma quick_check").fetchone()[0]
assert check == "ok", check
assert fts == chunks, f"fts rows {fts} != chunks {chunks}"
hits = db.execute("select count(*) from chunks_fts where chunks_fts match ?", ('"entropy"',)).fetchone()[0]
assert hits > 0, "no FTS hits for a known term"
print(f"   ok    {docs} docs, {chunks} chunks, quick_check=ok, sample query returned {hits} rows")
PY
  [ $? -ne 0 ] && bad "corpus.sqlite"
else
  bad "App/Resources/corpus.sqlite missing (run make corpus && make index)"
fi

step "model catalog"
"$PY" - <<'PY' || fail=1
import json, re
cat = json.load(open("App/Resources/models.json"))
ids = [m["id"] for m in cat["models"]]
assert len(ids) == len(set(ids)), "duplicate model ids"
assert cat["default_model"] in ids, "default_model not in catalog"
for m in cat["models"]:
    assert re.fullmatch(r"[0-9a-f]{64}", m["sha256"]), f"{m['id']}: bad sha256"
    assert m["size_bytes"] > 0 and m["file"].endswith(".gguf")
    assert m["url"].startswith("https://huggingface.co/")
    assert m["context_train"] >= 2048 and m["recommended_context"] <= m["context_train"]
print(f"   ok    {len(ids)} profiles, all checksums well-formed, default={cat['default_model']}")
PY

step "shell scripts (bash -n)"
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f (syntax)"; fi
done < <(find Scripts -name '*.sh' | sort)

step "python scripts (compileall)"
if "$PY" -m compileall -q Scripts >/dev/null 2>&1; then ok "Scripts/*.py compile"; else bad "python compile"; fi

step "offline deny-list"
if bash Scripts/check_offline.sh; then : ; else fail=1; fi

step "script smoke tests"
if "$PY" Scripts/build_index.py --help >/dev/null 2>&1; then ok "build_index.py --help"; else bad "build_index.py"; fi
if "$PY" Scripts/fetch_corpus.py --help >/dev/null 2>&1; then ok "fetch_corpus.py --help"; else bad "fetch_corpus.py"; fi
if "$PY" Scripts/eval_retrieval.py --help >/dev/null 2>&1; then ok "eval_retrieval.py --help"; else bad "eval_retrieval.py"; fi
if bash Scripts/fetch_model.sh --list >/dev/null 2>&1; then ok "fetch_model.sh --list"; else bad "fetch_model.sh --list"; fi

step "summary"
files=$(find . -type f -not -path './.git/*' -not -path './vendor/*' -not -path './.build/*' -not -path './Models/*' | wc -l | tr -d ' ')
echo "   $files tracked files"
if [ "$fail" -eq 0 ]; then echo "   verify_repo: PASS"; else echo "   verify_repo: FAIL"; fi
exit "$fail"
