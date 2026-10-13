#!/usr/bin/env bash
set -euo pipefail
export TAILSCALE_FIXTURE_LIBRARY=1
. "$(dirname "$0")/test_tailscale_setup.sh"
unset TAILSCALE_FIXTURE_LIBRARY
cat > "$WORK/bin/tput" <<'STUB'
#!/bin/bash
printf '%s\n' "${FIXTURE_COLUMNS:-120}"
STUB
chmod 700 "$WORK/bin/tput"
run_pair() {
 local answer="$1"; shift
 printf '%s\n' "$answer" | timeout 30 script -qefc "bash '$REPO_DIR/relay/tailscale-pair.sh' $*" /dev/null > "$CASE/output" 2>&1
}
new_case first-app-host
run_wizard y
! grep -q 'private-display' "$CASE/calls"
KEY_A="$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_RELAY_TOKEN)"
ID_A="$($TS_HELPER tailscale-state get "$STATE" instance)"
cp "$ENV_FILE" "$CASE/original.env"
: > "$CASE/calls"
run_pair ''
grep -Fxq 'private-display https://mini.tailtest.ts.net:8443 https://mini.tailtest.ts.net:8443' "$CASE/calls"
cmp -s "$ENV_FILE" "$CASE/original.env"
! grep -q 'systemctl --user restart' "$CASE/calls"
run_wizard y
cmp -s "$ENV_FILE" "$CASE/original.env"
for failure in arm app https; do
 export FAILURE="$failure"
 : > "$CASE/calls"
 if run_pair ''; then echo "pairing ignored $failure" >&2; exit 1; fi
 ! grep -q 'PRIVATE-PAIR-DISPLAY' "$CASE/output"
 ! grep -q 'private-display' "$CASE/calls"
 cmp -s "$ENV_FILE" "$CASE/original.env"
done
export FAILURE=none
export FIXTURE_COLUMNS=20
run_pair ''
grep -Fq 'Terminal too narrow' "$CASE/output"
unset FIXTURE_COLUMNS
if bash "$REPO_DIR/relay/tailscale-pair.sh" < /dev/null > "$CASE/output" 2>&1; then echo 'redirected invitation accepted' >&2; exit 1; fi
! grep -q 'PRIVATE-PAIR-DISPLAY' "$CASE/output"
# The terminal can stay open without blocking a separate lifecycle action.
mkfifo "$CASE/display-input"
exec 7<> "$CASE/display-input"
script -qefc "bash '$REPO_DIR/relay/tailscale-pair.sh'" /dev/null < "$CASE/display-input" > "$CASE/display-output" 2>&1 &
display_pid=$!
for _ in {1..100}; do
 grep -q 'press Enter to dismiss' "$CASE/display-output" && break
 /bin/sleep .05
done
if ! grep -q 'press Enter to dismiss' "$CASE/display-output"; then tail -30 "$CASE/display-output" >&2; kill "$display_pid"; wait "$display_pid" || true; exit 1; fi
if ! bash -c '. "$1/relay/common.sh"; relay_acquire_setup_lock "$2"' _ "$REPO_DIR" "${ENV_FILE%/*}"; then kill "$display_pid"; exit 1; fi
printf '\n' >&7
wait "$display_pid"
exec 7>&-
new_case second-app-client
export FIXTURE_HOST=second.tailtest.ts.net
run_wizard y --app-origin https://mini.tailtest.ts.net:8443
[[ "$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_PHONE_APP_URL)" == https://mini.tailtest.ts.net:8443 ]]
[[ "$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_RELAY_TOKEN)" != "$KEY_A" ]]
[[ "$($TS_HELPER tailscale-state get "$STATE" instance)" != "$ID_A" ]]
mkdir -p "${ENV_FILE%/*}/device-auth"
printf 'existing phone\n' > "${ENV_FILE%/*}/device-auth/sentinel"
run_pair ''
grep -Fxq 'private-display https://mini.tailtest.ts.net:8443 https://second.tailtest.ts.net:8443' "$CASE/calls"
run_wizard y
[[ "$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_PHONE_APP_URL)" == https://mini.tailtest.ts.net:8443 ]]
cp "$ENV_FILE" "$CASE/original.env"
for origin in https://public.example.test http://mini.tailtest.ts.net https://mini.tailtest.ts.net/path; do
 : > "$CASE/calls"
 if run_pair '' --app-origin "$origin"; then echo 'public/invalid app accepted' >&2; exit 1; fi
 ! grep -q 'private-display\|systemctl --user restart' "$CASE/calls"
 cmp -s "$ENV_FILE" "$CASE/original.env"
done
if run_pair n --app-origin https://third.tailtest.ts.net:8443; then echo 'cancelled app change accepted' >&2; exit 1; fi
cmp -s "$ENV_FILE" "$CASE/original.env"
# A failed restart restores the old env; if the fake manager also refuses the
# recovery restart, the evidence is retained and no invitation is emitted.
export FAILURE=service
if run_pair y --app-origin https://third.tailtest.ts.net:8443; then echo 'failed origin restart accepted' >&2; exit 1; fi
cmp -s "$ENV_FILE" "$CASE/original.env"
! grep -q 'PRIVATE-PAIR-DISPLAY' "$CASE/output"
export FAILURE=none
if run_pair ''; then echo 'pending app-origin recovery ignored' >&2; exit 1; fi
! grep -q 'PRIVATE-PAIR-DISPLAY' "$CASE/output"
# Simulate explicit owner review of this disposable, already-restored env:
# verify restart and move (never discard) the retained evidence aside.
bash "$REPO_DIR/relay/tailscale-control.sh" restart
for evidence in "${ENV_FILE%/*}"/app-origin-recovery.*; do mv "$evidence" "$CASE/owner-reviewed-${evidence##*/}"; done
run_pair $'y\n' --app-origin https://third.tailtest.ts.net:8443
[[ "$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_PHONE_APP_URL)" == https://third.tailtest.ts.net:8443 ]]
[[ "$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_ALLOWED_ORIGINS)" == *https://mini.tailtest.ts.net:8443* ]]
[[ "$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_RELAY_TOKEN)" == "$($TS_HELPER tailscale-preflight environment "$CASE/original.env" HERDR_RELAY_TOKEN)" ]]
[[ "$(< "${ENV_FILE%/*}/device-auth/sentinel")" == 'existing phone' ]]
# A changed DNS identity must not silently move either endpoint or app origin.
export FIXTURE_HOST=renamed.tailtest.ts.net
if run_pair ''; then echo 'hostname drift accepted' >&2; exit 1; fi
! grep -q 'PRIVATE-PAIR-DISPLAY' "$CASE/output"
new_case wizard-private-display
printf '\ny\n\n' | timeout 30 script -qefc "bash '$REPO_DIR/relay/tailscale-setup.sh'" /dev/null > "$CASE/output" 2>&1
grep -q 'PRIVATE-PAIR-DISPLAY' "$CASE/output"
for entrypoint in setup-link.sh plugin-setup-link.sh plugin-quick-start.sh; do
 printf '\n\n' | timeout 30 script -qefc "bash '$REPO_DIR/relay/$entrypoint'" /dev/null > "$CASE/output" 2>&1
 grep -q 'PRIVATE-PAIR-DISPLAY' "$CASE/output"
done
new_case interrupted-origin
run_wizard y
export FAILURE=kill-app-restart
if run_pair y --app-origin https://third.tailtest.ts.net:8443; then echo 'SIGKILL interruption ignored' >&2; exit 1; fi
export FAILURE=none
if run_pair ''; then echo 'interrupted app-origin change allowed an invitation' >&2; exit 1; fi
grep -Fq 'interrupted app-origin change needs review' "$CASE/output"
! grep -q 'PRIVATE-PAIR-DISPLAY' "$CASE/output"
echo 'Private pairing and shared app-origin fixtures passed'
