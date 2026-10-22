#!/usr/bin/env bash
# Fails if the app grows a network API. This is the enforcement behind the README's
# "no network code" claim, run by `make verify` and worth wiring into CI.
#
# OfflineGuard.swift is the single allowed exception: it exists to *block* network
# loads, so it necessarily names the URL loading machinery.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/App/Sources"
ALLOW="App/Sources/Safety/OfflineGuard.swift"

DENY=(
  'URLSession'
  'NSURLConnection'
  'CFStream'
  'CFHTTP'
  'NWConnection'
  'NWPathMonitor'
  'NWBrowser'
  'WebKit'
  'WKWebView'
  'SFSafariViewController'
  'ASWebAuthenticationSession'
  'getaddrinfo'
  'socket('
  'import Network'
  'import WebKit'
  'import SafariServices'
  'import CloudKit'
  'import MultipeerConnectivity'
)

fail=0
for pattern in "${DENY[@]}"; do
  hits="$(grep -rn --include='*.swift' -F "$pattern" "$SRC" 2>/dev/null | grep -v "$ALLOW" || true)"
  if [ -n "$hits" ]; then
    echo "FAIL  forbidden API '$pattern':" >&2
    echo "$hits" | sed 's/^/        /' >&2
    fail=1
  fi
done

# ATS must not be opened up: NSAllowsArbitraryLoads would permit cleartext if any
# dependency ever did try to use the network.
PLIST="$ROOT/App/Info.plist"
if [ -f "$PLIST" ]; then
  if grep -q 'NSAllowsArbitraryLoads' "$PLIST" && ! grep -A1 'NSAllowsArbitraryLoads' "$PLIST" | grep -q '<false/>'; then
    echo "FAIL  App/Info.plist permits arbitrary loads" >&2
    fail=1
  fi
fi

# The llama.cpp C sources are allowed to use sockets; the Swift app is not.
swift_files=$(find "$SRC" -name '*.swift' | wc -l | tr -d ' ')
if [ "$fail" -eq 0 ]; then
  echo "check_offline: ok ($swift_files Swift files, 0 network APIs)"
else
  echo "check_offline: FAILED" >&2
fi
exit "$fail"
