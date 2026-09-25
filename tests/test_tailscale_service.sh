#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'Skipping Linux-only Tailscale service fixtures'; exit 0; }
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-tailscale-service.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
mkdir -p "$WORK/home" "$WORK/bin" "$WORK/releases/current/relay"
export TEST_HELPER="$WORK/helper"
go build -o "$TEST_HELPER" "$REPO_DIR/cmd/herdr-mobile-relay"
export HOME="$WORK/home" HERDR_RELEASE_ROOT="$WORK/releases"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
export HERDR_RELAY_ENV="$WORK/relay.env" HERDR_RELAY_BIN="$WORK/bin/foreign"
export TEST_LAUNCH="$WORK/launched" TEST_UNEXPECTED="$WORK/unexpected"
cp "$REPO_DIR/relay/"{common,tailscale-service}.sh "$WORK/releases/current/relay/"
LAUNCHER="$WORK/releases/current/relay/tailscale-service.sh"
cat > "$WORK/releases/current/herdr-mobile-relay" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ "$1" == tailscale-preflight ]]; then exec "$TEST_HELPER" "$@"; fi
[[ "$*" == serve && "$HERDR_CONNECTION_MODE" == tailscale ]]
[[ "$HERDR_RELAY_HOST" == 127.0.0.1 && -z "$HERDR_GATEWAY_URL" ]]
[[ "$HERDR_TRANSPORT_FORCE_RELAY" == 1 && "$HERDR_REACHABILITY_PORT_MAPPING" == 0 && "$HERDR_RELAY_REARM_BOOTSTRAP" == 0 ]]
[[ "$HERDR_RELAY_TOKEN" == fixture-secret-not-for-output && "$HERDR_RELAY_INSTANCE_ID" == fixture-instance ]]
[[ "$HERDR_RELAY_SERVICE_NAME" == herdr-mobile-relay-tailscale.service ]]
[[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" && -z "${HERDR_RELAY_BIN:-}" ]]
[[ -z "${HERDR_SESSION:-}" && -z "${HERDR_CLIENT_SOCKET_PATH:-}" && -z "${HERDR_RELAY_SETUP_LOCK_FD:-}" ]]
[[ ! -e "/proc/$$/fd/$TEST_LOCK_FD" ]]
printf '%s\n' "$HERDR_SOCKET_PATH" > "$TEST_LAUNCH"
STUB
for name in tailscale cloudflared sudo systemctl foreign; do
 cat > "$WORK/bin/$name" <<'STUB'
#!/bin/bash
printf 'unexpected dependency\n' >> "$TEST_UNEXPECTED"
exit 99
STUB
 chmod 700 "$WORK/bin/$name"
done
chmod 700 "$WORK/releases/current/herdr-mobile-relay"
export PATH="$WORK/bin:$PATH"
cat > "$HERDR_RELAY_ENV" <<EOF
HERDR_CONNECTION_MODE='tailscale'
HERDR_RELAY_HOST='127.0.0.1'
HERDR_GATEWAY_URL=''
HERDR_TRANSPORT_FORCE_RELAY='1'
HERDR_REACHABILITY_PORT_MAPPING='0'
HERDR_RELAY_REARM_BOOTSTRAP='0'
HERDR_RELAY_TOKEN='fixture-secret-not-for-output'
HERDR_RELAY_INSTANCE_ID='fixture-instance'
HERDR_SOCKET_PATH='$WORK/selected.sock'
GH_TOKEN='fixture-release-secret'
GITHUB_TOKEN='fixture-release-secret'
HERDR_SESSION='wrong-inherited-session'
HERDR_CLIENT_SOCKET_PATH='/wrong-socket'
EOF
chmod 600 "$HERDR_RELAY_ENV"
cp "$HERDR_RELAY_ENV" "$WORK/before.env"
. "$REPO_DIR/relay/common.sh"
relay_acquire_setup_lock "$WORK"
export TEST_LOCK_FD="$HERDR_RELAY_SETUP_LOCK_FD"
bash "$LAUNCHER" > "$WORK/output" 2> "$WORK/error"
relay_drop_setup_lock "$WORK"
[[ "$(< "$TEST_LAUNCH")" == "$WORK/selected.sock" ]]
cmp -s "$HERDR_RELAY_ENV" "$WORK/before.env"
[[ ! -e "$TEST_UNEXPECTED" ]]
rm "$TEST_LAUNCH"
for unsafe in public symlink command mode; do
 cp "$WORK/before.env" "$HERDR_RELAY_ENV"; chmod 600 "$HERDR_RELAY_ENV"
 case "$unsafe" in
  public) chmod 644 "$HERDR_RELAY_ENV" ;;
  symlink) mv "$HERDR_RELAY_ENV" "$WORK/real.env"; ln -s "$WORK/real.env" "$HERDR_RELAY_ENV" ;;
  command) printf 'HERDR_RELAY_HOST= %s/bin/foreign\n' "$WORK" > "$HERDR_RELAY_ENV" ;;
  mode) grep -v '^HERDR_CONNECTION_MODE=' "$WORK/before.env" > "$HERDR_RELAY_ENV" ;;
 esac
 if HERDR_CONNECTION_MODE=tailscale bash "$LAUNCHER" > "$WORK/output" 2> "$WORK/error"; then echo "unsafe $unsafe accepted" >&2; exit 1; fi
 [[ ! -e "$TEST_LAUNCH" && ! -e "$TEST_UNEXPECTED" ]]
 if grep -q 'fixture-secret\|fixture-release-secret' "$WORK/output" "$WORK/error"; then echo 'secret leaked to diagnostics' >&2; exit 1; fi
 rm -f "$HERDR_RELAY_ENV"
done
echo 'Tailscale service launcher tests passed'
