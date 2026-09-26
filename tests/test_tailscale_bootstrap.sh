#!/usr/bin/env bash
set -euo pipefail
export TAILSCALE_FIXTURE_LIBRARY=1
. "$(dirname "$0")/test_tailscale_setup.sh"
unset TAILSCALE_FIXTURE_LIBRARY
new_bootstrap() {
 new_case "$1"
 runbook
 export ROOT="$HOME/.local/share/herdr-mobile-relay" CANDIDATE="$HOME/.local/share/herdr-mobile-relay/releases/fork"
 mkdir -p "$ROOT/releases"
 mv "$ROOT/current" "$ROOT/releases/upstream"
 cp "$ROOT/releases/upstream/herdr-mobile-relay" "$CASE/base-helper"
 ln -s releases/upstream "$ROOT/current"
 mkdir -p "$CANDIDATE/web" "$CANDIDATE/relay"
 cp "$REPO_DIR/relay/"*.sh "$CANDIDATE/relay/"
 cp "$REPO_DIR/install.sh" "$CANDIDATE/install.sh"
 cp "$ROOT/releases/upstream/web/release.json" "$CANDIDATE/web/release.json"
 cat > "$ROOT/releases/upstream/herdr-mobile-relay" <<'STUB'
#!/bin/bash
# Simulate the installed upstream bundle, which has no Tailscale helpers.
case "$1" in verify-release) exit 0 ;; *) echo 'old bundle cannot inspect private setup' >&2; exit 99 ;; esac
STUB
 rm "$ROOT/releases/upstream/relay/tailscale-service.sh"
 cat > "$CANDIDATE/herdr-mobile-relay" <<'STUB'
#!/bin/bash
set -eu
case "$1" in
 verify-release) [[ "$FAILURE" != candidate ]] || exit 1; exit 0 ;;
 activate-release)
  ln -s "$3" "$2/.fixture-release"
  mv -Tf "$2/.fixture-release" "$2/current"
  if [[ "$FAILURE" == kill-activate ]]; then kill -KILL "$PPID"; exit 137; fi
  exit 0 ;;
esac
exec "$CASE/base-helper" "$@"
STUB
 chmod 700 "$ROOT/releases/upstream/herdr-mobile-relay" "$CANDIDATE/herdr-mobile-relay"
 cp "$ENV_FILE" "$CASE/before.env"
 cp "$UNIT" "$CASE/before.unit"
 : > "$CASE/calls"
}
bootstrap() {
 local answer="$1"; shift
 printf '%s\n' "$answer" | timeout 30 script -qefc "bash '$CANDIDATE/relay/tailscale-setup.sh' --release-directory '$CANDIDATE' --no-pair $*" /dev/null > "$CASE/output" 2>&1
}
new_bootstrap cancelled
if bootstrap n --adopt-runbook; then echo 'cancelled bootstrap accepted' >&2; exit 1; fi
[[ "$(realpath "$ROOT/current")" == "$ROOT/releases/upstream" ]]
cmp "$ENV_FILE" "$CASE/before.env"
new_bootstrap success
bootstrap y --adopt-runbook
[[ "$(phase)" == verified && "$(realpath "$ROOT/current")" == "$CANDIDATE" ]]
[[ "$($TS_HELPER tailscale-preflight environment "$ENV_FILE" HERDR_RELAY_TOKEN)" == "$($TS_HELPER tailscale-preflight environment "$CASE/before.env" HERDR_RELAY_TOKEN)" ]]
! grep -q 'tailscale serve --' "$CASE/calls"
for failure in candidate https; do
 new_bootstrap "$failure"
 export FAILURE="$failure"
 if bootstrap y --adopt-runbook; then echo "bootstrap ignored $failure" >&2; exit 1; fi
 [[ "$(realpath "$ROOT/current")" == "$ROOT/releases/upstream" ]]
 cmp "$ENV_FILE" "$CASE/before.env"
 cmp "$UNIT" "$CASE/before.unit"
 ! grep -q 'tailscale serve --' "$CASE/calls"
done
new_bootstrap interrupted
export FAILURE=kill-activate
if bootstrap y --adopt-runbook; then echo 'interrupted bootstrap accepted' >&2; exit 1; fi
[[ "$(phase)" == prepared && "$(realpath "$ROOT/current")" == "$CANDIDATE" ]]
export FAILURE=none
bootstrap y --recover
[[ "$(phase)" == rolled-back && "$(realpath "$ROOT/current")" == "$ROOT/releases/upstream" ]]
cmp "$ENV_FILE" "$CASE/before.env"
cmp "$UNIT" "$CASE/before.unit"
# Retrying the reviewed adoption still retains the original credentials.
bootstrap y --adopt-runbook
[[ "$(phase)" == verified && "$(realpath "$ROOT/current")" == "$CANDIDATE" ]]
echo 'Explicit staged runbook bootstrap and release rollback fixtures passed'
