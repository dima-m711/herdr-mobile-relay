#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-tailscale-common.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
mkdir -p "$WORK/bin" "$WORK/home"
export HERDR_RELEASE_ROOT="$WORK/releases"
export HERDR_RELAY_BIN="$WORK/relay"
export TS_LOG="$WORK/calls" TS_VERSION=1.102.3 TS_STATUS=running TS_SERVE=empty
# This is a test-only build; installed helpers must use the packaged binary.
(cd "$REPO_DIR" && go build -o "$HERDR_RELAY_BIN" ./cmd/herdr-mobile-relay)
export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
cat > "$WORK/bin/tailscale" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TS_LOG"
case "$*" in
 version) printf '%s\n' "$TS_VERSION" ;;
 'status --json --peers=false')
  if [ "$TS_STATUS" = running ]; then
   printf '%s\n' '{"BackendState":"Running","Self":{"DNSName":"mini.tailtest.ts.net."},"Peer":{"secret":"must-not-print"}}'
  else printf '%s\n' '{"BackendState":"NeedsLogin"}'; fi ;;
 'serve status --json')
  case "$TS_SERVE" in
   empty) echo '{}' ;;
   denied) exit 1 ;;
   public) echo '{"AllowFunnel":{"mini.tailtest.ts.net:8443":true}}' ;;
  esac ;;
 *) echo 'unexpected Tailscale mutation' >&2; exit 99 ;;
esac
STUB
chmod 700 "$WORK/bin/tailscale"
export PATH="$WORK/bin:$PATH"
source "$REPO_DIR/relay/common.sh"
source "$REPO_DIR/relay/tailscale-common.sh"

if PATH="$WORK/missing" tailscale_hostname > "$WORK/output" 2> "$WORK/error"; then echo 'missing Tailscale accepted' >&2; exit 1; fi
[ ! -s "$WORK/output" ]
[ "$(tailscale_hostname)" = mini.tailtest.ts.net ]
IFS=$'\t' read -r state origin target digest < <(tailscale_serve_inspect mini.tailtest.ts.net 8443 8375)
[ "$state" = absent ] && [ "$origin" = https://mini.tailtest.ts.net:8443 ]
[ "$target" = http://127.0.0.1:8375 ] && [ "${#digest}" = 64 ]
for version in 1.50.0 not-a-version; do
 export TS_VERSION="$version"
 if tailscale_hostname > "$WORK/output" 2> "$WORK/error"; then echo 'unsupported client accepted' >&2; exit 1; fi
 [ ! -s "$WORK/output" ]
done
export TS_VERSION=1.102.3 TS_STATUS=logged-out
if tailscale_hostname > "$WORK/output" 2> "$WORK/error"; then echo 'logged-out client accepted' >&2; exit 1; fi
[ ! -s "$WORK/output" ]
export TS_STATUS=running
for mode in denied public; do
 export TS_SERVE="$mode"
 if tailscale_serve_inspect mini.tailtest.ts.net 8443 8375 > "$WORK/output" 2> "$WORK/error"; then echo 'unsafe Serve state accepted' >&2; exit 1; fi
 [ ! -s "$WORK/output" ]
done
if grep -q 'must-not-print' "$WORK/output" "$WORK/error"; then echo 'inventory leaked' >&2; exit 1; fi
if grep -Ev '^(version|status --json --peers=false|serve status --json)$' "$TS_LOG"; then echo 'unexpected CLI command' >&2; exit 1; fi
echo 'Tailscale inspection shell tests passed'
