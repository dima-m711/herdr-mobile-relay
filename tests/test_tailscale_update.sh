#!/usr/bin/env bash
set -euo pipefail
export TAILSCALE_FIXTURE_LIBRARY=1
. "$(dirname "$0")/test_tailscale_setup.sh"
unset TAILSCALE_FIXTURE_LIBRARY
SOURCE="$WORK/update-source"
mkdir -p "$SOURCE/relay"
cp "$REPO_DIR/relay/"*.sh "$SOURCE/relay/"
printf 'version = "9.9.9"\n' > "$SOURCE/herdr-plugin.toml"
cp "$WORK/bin/curl" "$WORK/base-curl"
cp "$WORK/bin/systemctl" "$WORK/base-systemctl"
cat > "$SOURCE/install.sh" <<'STUB'
#!/bin/bash
set -eu
[ "$HERDR_RELEASE_STAGE_ONLY" = 1 ] && [ "$HERDR_RELEASE_REQUIRED_MODE" = tailscale ] && [ "$HERDR_RELEASE_REPOSITORY" = dima-m711/herdr-mobile-relay ] || exit 99
printf 'stage-only\n' >> "$CASE/calls"
[ "$FAILURE" != download ] || exit 1
[ "$FAILURE" != staging-drift ] || printf '# external edit\n' >> "$ENV_FILE"
printf '%s\n' "$CANDIDATE"
STUB
cat > "$WORK/update-curl" <<'STUB'
#!/bin/bash
set -eu
version=$(< "$CASE/running")
if [[ "$FAILURE" == https-new && "$version" == new && "$*" == *https://* ]]; then exit 7; fi
reply=$("$STAGE_WORK/base-curl" "$@")
reply=${reply//\"release_version\":\"fixture\"/\"release_version\":\"$version\"}
printf '%s\n' "$reply"
STUB
cat > "$WORK/update-systemctl" <<'STUB'
#!/bin/bash
set -eu
if [[ "$*" == '--user restart herdr-mobile-relay-tailscale.service' ]]; then
 version=$(< "$HOME/.local/share/herdr-mobile-relay/current/.update-id")
 if [[ "$version" == new ]]; then
  case "$FAILURE" in
   restart-new) exit 1 ;;
   kill-update) kill -KILL "$PPID"; exit 137 ;;
   unit-drift) printf '# external edit\n' >> "$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service" ;;
  esac
 fi
 printf '%s\n' "$version" > "$CASE/running"
fi
exec "$STAGE_WORK/base-systemctl" "$@"
STUB
chmod 700 "$WORK/update-curl" "$WORK/update-systemctl" "$WORK/base-curl" "$WORK/base-systemctl"
export STAGE_WORK="$WORK"
new_update_case() {
 cp "$WORK/base-curl" "$WORK/bin/curl"
 cp "$WORK/base-systemctl" "$WORK/bin/systemctl"
 new_case "$1"
 run_wizard y
 export ROOT="$HOME/.local/share/herdr-mobile-relay" CANDIDATE="$HOME/.local/share/herdr-mobile-relay/releases/new"
 mkdir -p "$ROOT/releases"
 mv "$ROOT/current" "$ROOT/releases/old"
 ln -s releases/old "$ROOT/current"
 cp -R "$ROOT/releases/old" "$CANDIDATE"
 cp "$ROOT/releases/old/herdr-mobile-relay" "$CASE/base-helper"
 for id in old new; do
  printf '%s\n' "$id" > "$ROOT/releases/$id/.update-id"
  cat > "$ROOT/releases/$id/herdr-mobile-relay" <<'STUB'
#!/bin/bash
set -eu
id=$(< "$(dirname "$0")/.update-id")
case "$*" in
 'version --json') printf '{"version":"%s","revision":"fixture"}\n' "$id"; exit 0 ;;
 'verify-release '*) [[ "$id" != new || "$FAILURE" != incompatible ]] || exit 1; exit 0 ;;
 'activate-release '*) printf 'activate %s\n' "$3" >> "$CASE/calls"; ln -s "$3" "$2/.fixture-next"; mv -Tf "$2/.fixture-next" "$2/current"; exit 0 ;;
esac
exec "$CASE/base-helper" "$@"
STUB
  chmod 700 "$ROOT/releases/$id/herdr-mobile-relay"
 done
 printf 'old\n' > "$CASE/running"
 cp "$WORK/update-curl" "$WORK/bin/curl"
 cp "$WORK/update-systemctl" "$WORK/bin/systemctl"
 mkdir -p "${ENV_FILE%/*}/device-auth"
 printf 'paired phone\n' > "${ENV_FILE%/*}/device-auth/keep"
 cp "$ENV_FILE" "$CASE/original.env"
 cp "$UNIT" "$CASE/original.unit"
 cp "$STATE" "$CASE/original.state"
 : > "$CASE/calls"
}
run_update() { bash "$SOURCE/relay/tailscale-update.sh" 9.9.9 > "$CASE/output" 2>&1; }
unchanged_private_data() {
 cmp "$ENV_FILE" "$CASE/original.env"
 cmp "$UNIT" "$CASE/original.unit"
 cmp "$STATE" "$CASE/original.state"
 [[ "$(< "${ENV_FILE%/*}/device-auth/keep")" == 'paired phone' ]]
 ! grep -Eq 'tailscale serve --|enable |disable |daemon-reload|private-display|cloudflared|gateway|migrating' "$CASE/calls"
}
new_update_case success
run_update
[[ "$(realpath "$ROOT/current")" == "$CANDIDATE" && "$(< "$CASE/running")" == new ]]
unchanged_private_data
: > "$CASE/calls"
run_update
! grep -q 'restart\|activate ' "$CASE/calls"
new_update_case inactive
rm "$CASE/active" "$CASE/enabled"
run_update
[[ "$(realpath "$ROOT/current")" == "$CANDIDATE" && ! -e "$CASE/active" && ! -e "$CASE/enabled" ]]
! grep -q restart "$CASE/calls"
unchanged_private_data
for failure in download incompatible restart-new https-new; do
 new_update_case "$failure"
 export FAILURE="$failure"
 if run_update; then echo "update ignored $failure" >&2; exit 1; fi
 [[ "$(realpath "$ROOT/current")" == "$ROOT/releases/old" ]]
 unchanged_private_data
 [[ -z "$(find "${ENV_FILE%/*}" -maxdepth 1 -name 'update-recovery.*' -print -quit)" ]]
done
new_update_case plugin-dispatch
HERDR_PLUGIN_CONFIG_DIR="${ENV_FILE%/*}" bash "$SOURCE/relay/plugin-build.sh" > "$CASE/output" 2>&1
[[ "$(realpath "$ROOT/current")" == "$CANDIDATE" ]]
unchanged_private_data
new_update_case contention
(
 . "$REPO_DIR/relay/common.sh"
 relay_acquire_setup_lock "${ENV_FILE%/*}"
 if env -u HERDR_RELAY_SETUP_LOCK_FD bash "$SOURCE/relay/tailscale-update.sh" 9.9.9 > "$CASE/output" 2>&1; then exit 99; fi
)
! grep -q stage-only "$CASE/calls"
new_update_case foreign-unit
printf '# foreign\n' >> "$UNIT"
if run_update; then echo 'foreign unit accepted' >&2; exit 1; fi
! grep -q stage-only "$CASE/calls"
for failure in staging-drift unit-drift kill-update; do
 new_update_case "$failure"
 export FAILURE="$failure"
 if run_update; then echo "update ignored $failure" >&2; exit 1; fi
 export FAILURE=none
 if [[ "$failure" == staging-drift ]]; then
  [[ "$(realpath "$ROOT/current")" == "$ROOT/releases/old" ]]
  grep -q 'external edit' "$ENV_FILE"
 else
  [[ -n "$(find "${ENV_FILE%/*}" -maxdepth 1 -name 'update-recovery.*' -print -quit)" ]]
  if run_update; then echo 'interrupted update automatically replayed' >&2; exit 1; fi
  if bash "$REPO_DIR/relay/tailscale-control.sh" restart > "$CASE/output" 2>&1; then echo 'pending update restart accepted' >&2; exit 1; fi
 fi
done
echo 'Private update cutover, rollback and interruption fixtures passed'
