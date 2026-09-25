#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Linux || "$(id -u)" == 0 ]]; then echo 'Skipping Tailscale wizard fixtures: ordinary Linux user required'; exit 0; fi
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-tailscale-setup.XXXXXX")"
trap 'status=$?; if [[ "$status" != 0 ]]; then echo "Failed fixture: ${CASE:-build}" >&2; [[ ! -f "${CASE:-}/output" ]] || tail -20 "$CASE/output" >&2; fi; rm -rf "$WORK"; exit "$status"' EXIT
export TS_HELPER="$WORK/helper" TEST_REPO="$REPO_DIR"
go build -o "$TS_HELPER" "$REPO_DIR/cmd/herdr-mobile-relay"
BASE_PATH="$PATH"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "$CASE/calls"
case "$*" in
 '--user show-environment'|'--user daemon-reload') exit 0 ;;
 *'is-active --quiet '*) [[ "${*: -1}" == herdr-mobile-relay-tailscale.service && -f "$CASE/active" ]] && exit 0; exit 3 ;;
 *'is-enabled --quiet '*) [[ "${*: -1}" == herdr-mobile-relay-tailscale.service && -f "$CASE/enabled" ]] && exit 0; exit 1 ;;
 '--user show herdr-mobile-relay-tailscale.service --property MainPID --value') echo 12345 ;;
 '--user show herdr-mobile-relay-tailscale.service --property FragmentPath --value') echo "$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service" ;;
 '--user show herdr-mobile-relay-tailscale.service --property DropInPaths --value') [[ "$FAILURE" != dropin ]] || echo '/foreign-override.conf' ;;
 '--user enable herdr-mobile-relay-tailscale.service') touch "$CASE/enabled" ;;
 '--user restart herdr-mobile-relay-tailscale.service')
  if [[ "$FAILURE" == kill-app-restart ]]; then kill -KILL "$PPID"; exit 137; fi
  [[ "$FAILURE" != service ]] || exit 1; touch "$CASE/active" ;;
 '--user stop herdr-mobile-relay-tailscale.service') [[ -f "$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service" ]] || exit 5; rm -f "$CASE/active" ;;
 '--user disable herdr-mobile-relay-tailscale.service') rm -f "$CASE/enabled" ;;
 '--user disable --now herdr-mobile-relay-tailscale.service') [[ "$FAILURE" != disable ]] || exit 1; rm -f "$CASE/active" "$CASE/enabled" ;;
 *) exit 99 ;;
esac
STUB
cat > "$WORK/bin/tailscale" <<'STUB'
#!/bin/bash
printf 'tailscale %s\n' "$*" >> "$CASE/calls"
case "$*" in
 version) echo 1.102.3 ;;
 'status --json --peers=false') printf '{"BackendState":"Running","Self":{"DNSName":"%s."}}\n' "$FIXTURE_HOST" ;;
 'serve status --json')
  target=8375; other=9000
  [[ "$FAILURE" != conflict ]] || target=9001
  [[ ! -f "$CASE/admin-change" ]] || other=9999
  if [[ -f "$CASE/route" || "$FAILURE" == conflict ]]; then
   printf '{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},"Web":{"other.tailtest.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:%s"}}},"%s:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:%s"}}}},"AllowFunnel":{"other.tailtest.ts.net:443":true}}\n' "$other" "$FIXTURE_HOST" "$target"
  else
   printf '{"TCP":{"443":{"HTTPS":true}},"Web":{"other.tailtest.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:%s"}}}},"AllowFunnel":{"other.tailtest.ts.net:443":true}}\n' "$other"
  fi ;;
 'serve --bg --https=8443 http://127.0.0.1:8375')
  [[ "$FAILURE" != denied ]] || exit 1
  touch "$CASE/route"
  [[ "$FAILURE" != concurrent ]] || touch "$CASE/admin-change"
  [[ "$FAILURE" != kill-serve ]] || kill -KILL "$FIXTURE_WIZARD_PID"
  ;;
 'serve --https=8443 off') [[ "$FAILURE" != rollback ]] || exit 1; rm -f "$CASE/route" ;;
 *) exit 99 ;;
esac
STUB
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
case "$*" in
 *'/version.json'*)
  [[ "$FAILURE" != app ]] || exit 7
  printf '{"version":"fixture","assets":1}\n'; exit 0 ;;
esac
[[ -f "$CASE/active" ]] || exit 7
instance="$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_RELAY_INSTANCE_ID)" || exit 1
case "$*" in
 *https://*) [[ -f "$CASE/route" ]] || exit 7; case "$FAILURE" in https|rollback) instance=foreign ;; drift) printf 'foreign unit\n' > "$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service"; instance=foreign ;; esac ;;
esac
printf '{"status":"ready","inventory":{"state":"ready"},"instance":"%s","release_version":"fixture","revision":"fixture","bundle_hash":"fixture","protocol":3,"gateway":{"enabled":false,"registered":false}}\n' "$instance"
STUB
for command in sleep systemd-analyze herdr; do printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/$command"; done
cat > "$WORK/bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >> "$CASE/calls"
[[ "$FAILURE" != sudo ]] || exit 1
[[ "$1" == -- ]] && shift
exec "$@"
STUB
chmod 700 "$WORK/bin/"*

new_case() {
 export CASE="$WORK/$1" HOME="$WORK/$1/home" FAILURE=none FIXTURE_HOST=mini.tailtest.ts.net
 export PATH="$WORK/bin:$BASE_PATH" HERDR_BIN="$WORK/bin/herdr" HERDR_SOCKET_PATH="$HOME/.config/herdr/herdr.sock" SHELL=/bin/bash
 unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR HERDR_RELEASE_ROOT HERDR_RELAY_ENV HERDR_PLUGIN_CONFIG_DIR HERDR_RELAY_BIN
 mkdir -p "$HOME/.local/bin"
 for fake in "$WORK/bin/"*; do ln -s "$fake" "$HOME/.local/bin/${fake##*/}"; done
 export ENV_FILE="$HOME/.config/herdr/plugins/config/herdr-mobile-relay.events/relay.env"
 STATE="${ENV_FILE%/*}/tailscale-setup.json"
 UNIT="$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service"
 mkdir -p "$HOME/.local/share/herdr-mobile-relay/current/relay" "$HOME/.local/share/herdr-mobile-relay/current/web"
 cp "$REPO_DIR/relay/tailscale-service.sh" "$HOME/.local/share/herdr-mobile-relay/current/relay/"
 printf '{"bundle_hash":"fixture"}\n' > "$HOME/.local/share/herdr-mobile-relay/current/web/release.json"
 cat > "$HOME/.local/share/herdr-mobile-relay/current/herdr-mobile-relay" <<'STUB'
#!/bin/bash
if [[ "$1" == tailscale-state && ( "$2" == prepare || "$2" == advance ) ]]; then
 "$TS_HELPER" "$@" || exit $?
 phase=prepared; [[ "$2" != advance ]] || phase="$5"
 if [[ "$FAILURE" == "kill-$phase" ]]; then kill -KILL "$PPID"; fi
 exit 0
fi
case "$*" in
 'version --json') echo '{"version":"fixture","revision":"fixture"}'; exit 0 ;;
 'tailscale-pairing show '*)
  [[ "$FAILURE" != arm ]] || exit 1
  printf 'private-display %s %s\n' "$5" "$6" >> "$CASE/calls"
  echo 'PRIVATE-PAIR-DISPLAY (synthetic fixture, no credential)'
  [[ "$8" -ge 80 ]] || echo 'Terminal too narrow; widen and regenerate.'
  exit 0 ;;
 'tailscale-preflight session '*|'tailscale-preflight listener '*|'tailscale-preflight ports '*) printf 'probe %s\n' "$*" >> "$CASE/calls"; exit 0 ;;
esac
exec "$TS_HELPER" "$@"
STUB
 chmod 700 "$HOME/.local/share/herdr-mobile-relay/current/herdr-mobile-relay"
}
run_wizard() {
 local answer="$1"; shift
 printf '%s\n' "$answer" | timeout 30 script -qefc "export FIXTURE_WIZARD_PID=\$\$; exec bash '$REPO_DIR/relay/tailscale-setup.sh' --no-pair $*" /dev/null > "$CASE/output" 2>&1
}
run_teardown() {
 local answer="$1"; shift
 printf '%s\n' "$answer" | timeout 30 script -qefc "bash '$REPO_DIR/relay/tailscale-teardown.sh' $*" /dev/null > "$CASE/output" 2>&1
}
runbook() {
 mkdir -p "${ENV_FILE%/*}/device-auth" "${UNIT%/*}"
 chmod 700 "${ENV_FILE%/*}"
 cp "$REPO_DIR/tests/fixtures/tailscale-runbook.service" "$UNIT"
 cp "$REPO_DIR/tests/fixtures/tailscale-runbook-launcher.sh" "${ENV_FILE%/*}/start-tailscale-relay.sh"
 chmod 644 "$UNIT"; chmod 700 "${ENV_FILE%/*}/start-tailscale-relay.sh"
 printf 'paired device fixture\n' > "${ENV_FILE%/*}/device-auth/sentinel"
 cat > "$ENV_FILE" <<ENV
HERDR_RELAY_TOKEN='0123456789abcdef0123456789abcdef'
HERDR_RELAY_INSTANCE_ID='runbook-instance'
HERDR_RELAY_PORT=8375
HERDR_RELAY_PLUGIN_PORT=8376
HERDR_RELEASE_ROOT='$HOME/.local/share/herdr-mobile-relay'
HERDR_BIN='$HERDR_BIN'
HERDR_SOCKET_PATH='$HERDR_SOCKET_PATH'
HERDR_GATEWAY_URL=''
HERDR_PHONE_APP_URL='https://mini.tailtest.ts.net:8443'
ENV
 chmod 600 "$ENV_FILE"
 cp -p "$ENV_FILE" "$CASE/original.env"; cp -p "$UNIT" "$CASE/original.unit"
 touch "$CASE/active" "$CASE/enabled" "$CASE/route"
}
phase() { "$TS_HELPER" tailscale-state get "$STATE" phase; }
if [[ "${TAILSCALE_FIXTURE_LIBRARY:-}" == 1 ]]; then return 0; fi
new_case cancelled
if run_wizard n; then echo 'cancellation accepted' >&2; exit 1; fi
[[ ! -e "$ENV_FILE" && ! -e "$UNIT" && ! -e "$STATE" ]]
new_case conflict
export FAILURE=conflict
if run_wizard y; then echo 'conflict accepted' >&2; exit 1; fi
[[ ! -e "$ENV_FILE" && ! -e "$UNIT" && ! -e "$STATE" ]]
new_case fresh
run_wizard y || { echo 'fresh setup failed' >&2; tail -25 "$CASE/output" >&2; exit 1; }
[[ "$(phase)" == verified && -f "$CASE/route" && -f "$CASE/active" ]]
cp "$ENV_FILE" "$CASE/env-before"
cp "$CASE/calls" "$CASE/calls-before"
run_wizard y
cmp -s "$ENV_FILE" "$CASE/env-before"
[[ "$(grep -c 'tailscale serve --bg' "$CASE/calls")" == 1 ]]
key="$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_RELAY_TOKEN)"
if grep -Fq "$key" "$CASE/output"; then echo 'setup leaked key' >&2; exit 1; fi
for failure in denied https rollback concurrent service sudo drift; do
 new_case "$failure"
 export FAILURE="$failure"
 flags=''; [[ "$failure" != sudo ]] || flags=--sudo
 if run_wizard y "$flags"; then echo "$failure was accepted" >&2; exit 1; fi
 if [[ "$failure" == drift ]]; then
  [[ "$(phase)" == recovery && -e "$ENV_FILE" && -e "$CASE/active" && ! -e "$CASE/route" ]]
  grep -Fxq 'foreign unit' "$UNIT"
  continue
 fi
 [[ ! -e "$UNIT" && ! -e "$ENV_FILE" && ! -e "$CASE/active" ]]
 case "$failure" in
  rollback|concurrent) [[ "$(phase)" == recovery && -f "$CASE/route" ]] ;;
  *) [[ "$(phase)" == rolled-back && ! -e "$CASE/route" ]] ;;
 esac
 if [[ "$failure" == rollback ]]; then
  export FAILURE=none
  run_wizard y --recover
  [[ "$(phase)" == rolled-back && ! -e "$CASE/route" ]]
 fi
 if [[ "$failure" == concurrent ]]; then
  export FAILURE=none
  run_wizard y --recover --keep-route
  [[ "$(phase)" == rolled-back && -e "$CASE/route" && -e "$CASE/admin-change" ]]
  run_wizard y
  [[ "$(phase)" == verified && "$($TS_HELPER tailscale-state get "$STATE" route_ownership)" == adopted && -e "$CASE/admin-change" ]]
 fi
 if [[ "$failure" == denied ]]; then
  before="$($TS_HELPER tailscale-state get "$STATE" instance)"
  export FAILURE=none
  run_wizard y
  [[ "$(phase)" == verified && "$($TS_HELPER tailscale-state get "$STATE" instance)" == "$before" ]]
 fi
done
new_case teardown
run_wizard y
cp "$ENV_FILE" "$CASE/preserved.env"
mkdir -p "${ENV_FILE%/*}/device-auth"
printf 'paired fixture\n' > "${ENV_FILE%/*}/device-auth/sentinel"
if run_teardown n; then echo 'teardown cancellation ignored' >&2; exit 1; fi
[[ "$(phase)" == verified && -e "$CASE/active" && -e "$CASE/route" ]]
export FAILURE=disable
if run_teardown y; then echo 'disable failure ignored' >&2; exit 1; fi
[[ "$(phase)" == teardown-pending && ! -e "$CASE/route" && -e "$UNIT" ]]
export FAILURE=none
run_teardown y
[[ "$(phase)" == removed && ! -e "$UNIT" && ! -e "$CASE/active" && ! -e "$CASE/route" ]]
cmp -s "$ENV_FILE" "$CASE/preserved.env"
grep -Fxq 'paired fixture' "${ENV_FILE%/*}/device-auth/sentinel"
run_teardown y
run_wizard y
[[ "$(phase)" == verified && -e "$CASE/route" ]]
[[ "$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_RELAY_TOKEN)" == "$($TS_HELPER tailscale-preflight environment "$CASE/preserved.env" HERDR_RELAY_TOKEN)" ]]

for failure in none https; do
 new_case "adoption-$failure"
 runbook
 export FAILURE="$failure"
 if run_wizard y --adopt-runbook; then
  [[ "$failure" == none && "$(phase)" == verified ]]
  [[ "$($TS_HELPER tailscale-state get "$STATE" route_ownership)" == adopted ]]
  [[ "$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_RELAY_TOKEN)" == 0123456789abcdef0123456789abcdef ]]
  run_teardown y
  [[ "$(phase)" == removed && -e "$CASE/route" && ! -e "$UNIT" ]]
 else
  [[ "$failure" == https && "$(phase)" == rolled-back && -e "$CASE/route" && -e "$CASE/active" && -e "$CASE/enabled" ]]
  cmp -s "$ENV_FILE" "$CASE/original.env"; cmp -s "$UNIT" "$CASE/original.unit"
  [[ "$(stat -c %a "$UNIT")" == 644 ]]
 fi
 grep -Fxq 'paired device fixture' "${ENV_FILE%/*}/device-auth/sentinel"
 if grep -q 'tailscale serve --bg\|tailscale serve --https=8443 off' "$CASE/calls"; then echo 'adopted route mutated' >&2; exit 1; fi
done
for unsafe in foreign symlink dropin; do
 new_case "unsafe-$unsafe"
 runbook
 case "$unsafe" in
  foreign) printf '#!/bin/bash\ntouch %s/executed\n' "$CASE" > "$UNIT" ;;
  symlink) rm "$UNIT"; ln -s "$CASE/original.unit" "$UNIT" ;;
  dropin) export FAILURE=dropin ;;
 esac
 if run_wizard y --adopt-runbook; then echo "unsafe $unsafe accepted" >&2; exit 1; fi
 [[ ! -e "$STATE" && ! -e "$CASE/executed" && -e "$CASE/active" && -e "$CASE/route" ]]
 cmp -s "$ENV_FILE" "$CASE/original.env"
done
for point in prepared local-ready route-pending route-ready verified serve; do
 new_case "hard-interrupt-$point"
 export FAILURE="kill-$point"
 if run_wizard y; then echo "hard interruption $point did not interrupt" >&2; exit 1; fi
 identity="$($TS_HELPER tailscale-state get "$STATE" instance)"
 export FAILURE=none
 if [[ "$point" == verified ]]; then
  run_wizard y
  [[ "$(phase)" == verified && -e "$CASE/active" && -e "$CASE/route" ]]
  continue
 fi
 if [[ "$point" == prepared ]]; then
  recovery="$($TS_HELPER tailscale-state get "$STATE" recovery_directory)"
  cp -p "$recovery/state" "$CASE/valid-record"
  printf '\nactive=$(touch %s/executed)\n' "$CASE" >> "$recovery/state"
  if run_wizard y --recover; then echo 'malformed recovery accepted' >&2; exit 1; fi
  [[ ! -e "$CASE/executed" && "$(phase)" == prepared ]]
  cp -p "$CASE/valid-record" "$recovery/state"
 fi
 if [[ "$point" == serve ]]; then
  if run_wizard y --recover; then echo 'ambiguous interrupted Serve creation was claimed' >&2; exit 1; fi
  [[ "$(phase)" == recovery && -e "$CASE/route" ]]
  run_wizard y --recover --keep-route
 else
  run_wizard y --recover
  [[ ! -e "$CASE/route" ]]
 fi
 [[ "$(phase)" == rolled-back && ! -e "$UNIT" && ! -e "$ENV_FILE" && ! -e "$CASE/active" ]]
 run_wizard y
 [[ "$(phase)" == verified && "$($TS_HELPER tailscale-state get "$STATE" instance)" == "$identity" ]]
done
new_case teardown-interrupted
run_wizard y
export FAILURE=kill-teardown-pending
if run_teardown y; then echo 'teardown interruption ignored' >&2; exit 1; fi
[[ "$(phase)" == teardown-pending && -e "$CASE/route" && -e "$UNIT" ]]
export FAILURE=none
run_teardown y
[[ "$(phase)" == removed && ! -e "$CASE/route" && ! -e "$UNIT" ]]
new_case policy-drift
run_wizard y
printf "HERDR_CONNECTION_MODE=''\n" > "$ENV_FILE"
if run_wizard y; then echo 'managed policy drift accepted' >&2; exit 1; fi
if run_teardown y; then echo 'teardown ignored foreign configuration' >&2; exit 1; fi
[[ "$(phase)" == verified && -e "$CASE/active" && -e "$CASE/route" ]]
new_case noninteractive
if bash "$REPO_DIR/relay/tailscale-setup.sh" --no-pair < /dev/null > "$CASE/output" 2>&1; then echo 'noninteractive setup accepted' >&2; exit 1; fi
[[ ! -e "$STATE" && ! -e "$ENV_FILE" && ! -e "$UNIT" ]]
new_case eof
if printf '\004' | timeout 15 script -qefc "bash '$REPO_DIR/relay/tailscale-setup.sh' --no-pair" /dev/null > "$CASE/output" 2>&1; then
 echo 'EOF accepted' >&2; exit 1
else
 status=$?; [[ "$status" != 124 ]] || { echo 'EOF hung instead of cancelling' >&2; exit 1; }
fi
[[ ! -e "$STATE" && ! -e "$ENV_FILE" && ! -e "$UNIT" ]]
new_case transport-departure
run_wizard y
cp "$ENV_FILE" "$CASE/before.env"
if printf 'y\n' | timeout 15 script -qefc "bash '$REPO_DIR/relay/tailscale-switch.sh' community" /dev/null > "$CASE/output" 2>&1; then echo 'active private service switched' >&2; exit 1; fi
cmp -s "$ENV_FILE" "$CASE/before.env"
run_teardown y
if bash "$REPO_DIR/relay/tailscale-switch.sh" community < /dev/null > "$CASE/output" 2>&1; then echo 'noninteractive switch accepted' >&2; exit 1; fi
if printf 'n\n' | timeout 15 script -qefc "bash '$REPO_DIR/relay/tailscale-switch.sh' community" /dev/null > "$CASE/output" 2>&1; then echo 'cancelled switch accepted' >&2; exit 1; fi
cmp -s "$ENV_FILE" "$CASE/before.env"
mkdir -p "${ENV_FILE%/*}/device-auth"
printf 'keep device\n' > "${ENV_FILE%/*}/device-auth/sentinel"
: > "$CASE/calls"
printf 'y\n' | timeout 15 script -qefc "bash '$REPO_DIR/relay/tailscale-switch.sh' community" /dev/null > "$CASE/output" 2>&1
[[ -z "$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_CONNECTION_MODE)" ]]
[[ -z "$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_RELAY_SERVICE_NAME)" ]]
[[ "$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_RELAY_TOKEN)" == "$($TS_HELPER tailscale-preflight environment "$CASE/before.env" HERDR_RELAY_TOKEN)" ]]
[[ "$(< "${ENV_FILE%/*}/connection-method")" == community && "$(phase)" == removed ]]
[[ -f "${ENV_FILE%/*}/device-auth/sentinel" && ! -e "$UNIT" && ! -e "$CASE/route" ]]
if grep -Eq 'tailscale serve (--bg|--https)|systemctl --user (restart|enable|disable|stop)' "$CASE/calls"; then echo 'transport selection mutated a service/route' >&2; exit 1; fi
echo 'Tailscale wizard transaction fixtures passed'
