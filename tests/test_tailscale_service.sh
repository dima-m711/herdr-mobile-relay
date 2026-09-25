#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-tailscale-service.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
mkdir -p "$WORK/home" "$WORK/bin"
export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
export HERDR_RELEASE_ROOT="$WORK/releases"
export HERDR_RELAY_ENV="$WORK/relay.env" HERDR_RELAY_BIN="$WORK/bin/relay"
export TEST_LAUNCH="$WORK/launched" TEST_UNEXPECTED="$WORK/unexpected"
cat > "$HERDR_RELAY_BIN" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ "$*" == serve ]]
[[ "$HERDR_CONNECTION_MODE" == tailscale ]]
[[ "$HERDR_RELAY_HOST" == 127.0.0.1 && -z "$HERDR_GATEWAY_URL" ]]
[[ "$HERDR_TRANSPORT_FORCE_RELAY" == 1 && "$HERDR_REACHABILITY_PORT_MAPPING" == 0 && "$HERDR_RELAY_REARM_BOOTSTRAP" == 0 ]]
[[ "$HERDR_RELAY_TOKEN" == fixture-secret-not-for-output ]]
[[ "$HERDR_RELAY_INSTANCE_ID" == fixture-instance ]]
[[ "$HERDR_RELAY_SERVICE_NAME" == herdr-mobile-relay-tailscale.service ]]
[[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]
printf '%s\n' "$HERDR_SOCKET_PATH" > "$TEST_LAUNCH"
STUB
for name in tailscale cloudflared sudo systemctl; do
 cat > "$WORK/bin/$name" <<'STUB'
#!/bin/bash
printf 'unexpected dependency\n' >> "$TEST_UNEXPECTED"
exit 99
STUB
 chmod 700 "$WORK/bin/$name"
done
chmod 700 "$HERDR_RELAY_BIN"
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
EOF
chmod 600 "$HERDR_RELAY_ENV"
cp "$HERDR_RELAY_ENV" "$WORK/before.env"
bash "$REPO_DIR/relay/tailscale-service.sh" > "$WORK/output" 2> "$WORK/error"
[[ "$(< "$TEST_LAUNCH")" == "$WORK/selected.sock" ]]
cmp -s "$HERDR_RELAY_ENV" "$WORK/before.env"
[[ ! -e "$TEST_UNEXPECTED" ]]
rm "$TEST_LAUNCH"

chmod 644 "$HERDR_RELAY_ENV"
if bash "$REPO_DIR/relay/tailscale-service.sh" > "$WORK/output" 2> "$WORK/error"; then echo 'nonprivate environment accepted' >&2; exit 1; fi
[[ ! -e "$TEST_LAUNCH" ]]
chmod 600 "$HERDR_RELAY_ENV"
mv "$HERDR_RELAY_ENV" "$WORK/real.env"
ln -s "$WORK/real.env" "$HERDR_RELAY_ENV"
if bash "$REPO_DIR/relay/tailscale-service.sh" > "$WORK/output" 2> "$WORK/error"; then echo 'symlink environment accepted' >&2; exit 1; fi
[[ ! -e "$TEST_LAUNCH" ]]
rm "$HERDR_RELAY_ENV"
mv "$WORK/real.env" "$HERDR_RELAY_ENV"
printf "HERDR_CONNECTION_MODE=''\n" >> "$HERDR_RELAY_ENV"
if bash "$REPO_DIR/relay/tailscale-service.sh" > "$WORK/output" 2> "$WORK/error"; then echo 'unmarked mode accepted' >&2; exit 1; fi
[[ ! -e "$TEST_LAUNCH" ]]
if grep -q 'fixture-secret\|fixture-release-secret' "$WORK/output" "$WORK/error"; then echo 'secret leaked to diagnostics' >&2; exit 1; fi
[[ ! -e "$TEST_UNEXPECTED" ]]
echo 'Tailscale service launcher tests passed'
