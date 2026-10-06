#!/usr/bin/env bash
# Deterministic launchd adapter/transaction tests. Never talks to host launchd,
# Tailscale or the live relay; this is not native Mac acceptance evidence.
set -euo pipefail
SOURCE=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d /tmp/herdr-private-mac.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" TEST_MAC="$WORK/model"
mkdir -p "$HOME" "$TEST_MAC"
go build -o "$WORK/helper" "$SOURCE/cmd/herdr-mobile-relay"
. "$SOURCE/relay/common.sh"
. "$SOURCE/relay/tailscale-common.sh"
. "$SOURCE/relay/native-install-transaction.sh"
. "$SOURCE/relay/tailscale-transaction.sh"
. "$SOURCE/relay/tailscale-darwin.sh"
relay_binary() { printf '%s\n' "$WORK/helper"; }
uname() { if [ "${1:-}" = -s ]; then printf 'Darwin\n'; else command uname "$@"; fi; }
TAILSCALE_MANAGER=launchd
TAILSCALE_LABEL=com.herdr-mobile-relay.tailscale
TAILSCALE_CONFIG_DIR="$HOME/.config/herdr/plugins/config/herdr-mobile-relay.events"
TAILSCALE_ENV="$TAILSCALE_CONFIG_DIR/relay.env"
TAILSCALE_UNIT_DIR="$HOME/Library/LaunchAgents"
TAILSCALE_UNIT="$TAILSCALE_UNIT_DIR/$TAILSCALE_LABEL.plist"
TAILSCALE_RELEASE_ROOT="$HOME/.local/share/herdr-mobile-relay"
TAILSCALE_BINARY="$WORK/helper"
mkdir -p "$TAILSCALE_CONFIG_DIR" "$TAILSCALE_UNIT_DIR"
chmod 700 "$TAILSCALE_CONFIG_DIR"
export TAILSCALE_LABEL TAILSCALE_ENV TAILSCALE_UNIT TAILSCALE_RELEASE_ROOT
cat > "$WORK/launchctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_MAC/calls"
case "$1" in
 print)
  if [ "$2" = "gui/$UID" ]; then [ ! -e "$TEST_MAC/no-domain" ]; exit; fi
  if [ -f "$TEST_MAC/unloading" ]; then
   count=$(cat "$TEST_MAC/unloading")
   if [ "$count" -eq 0 ]; then rm -f "$TEST_MAC/unloading" "$TEST_MAC/loaded"
   else printf '%s\n' "$((count-1))" > "$TEST_MAC/unloading"; fi
  fi
  [ "$2" = "gui/$UID/$TAILSCALE_LABEL" ] && [ -e "$TEST_MAC/loaded" ] || exit 113
  cat "$TEST_MAC/cached"
  ;;
 list)
  printf 'PID\tStatus\tLabel\n'
  if [ -e "$TEST_MAC/loaded" ]; then printf '123\t0\t%s\n' "$TAILSCALE_LABEL"; fi
  ;;
 print-disabled)
  printf 'disabled services = {\n\t"%s" => ' "$TAILSCALE_LABEL"
  if [ -e "$TEST_MAC/disabled" ]; then printf true; else printf false; fi
  printf '\n}\n'
  ;;
 enable) [ "$2" = "gui/$UID/$TAILSCALE_LABEL" ]; rm -f "$TEST_MAC/disabled" ;;
 disable) [ "$2" = "gui/$UID/$TAILSCALE_LABEL" ]; touch "$TEST_MAC/disabled" ;;
 bootstrap)
  [ "$2" = "gui/$UID" ] && [ "$3" = "$TAILSCALE_UNIT" ]
  [ ! -e "$TEST_MAC/disabled" ] && [ ! -e "$TEST_MAC/fail-start" ] || exit 1
  if [ -f "$TEST_MAC/fail-once" ]; then rm "$TEST_MAC/fail-once"; exit 1; fi
  cp "$TEST_MAC/good" "$TEST_MAC/cached"; touch "$TEST_MAC/loaded"
  ;;
 bootout)
  [ "$2" = "gui/$UID/$TAILSCALE_LABEL" ]
  if [ -e "$TEST_MAC/delayed-stop" ]; then printf '2\n' > "$TEST_MAC/unloading"
  else rm "$TEST_MAC/loaded"; fi ;;
 kickstart) [ "$2" = "gui/$UID/$TAILSCALE_LABEL" ]; [ -e "$TEST_MAC/loaded" ] ;;
 *) exit 99 ;;
esac
SH
chmod +x "$WORK/launchctl"
tailscale_launchctl() { "$WORK/launchctl" "$@"; }
sleep() { :; } # bounded retry counts are checked without wall-clock delays
cat > "$TEST_MAC/good" <<EOF
gui/$UID/$TAILSCALE_LABEL = {
	path = $TAILSCALE_UNIT
	program = /bin/bash
	working directory = $TAILSCALE_RELEASE_ROOT/current
	arguments = {
		/bin/bash
		$TAILSCALE_RELEASE_ROOT/current/relay/tailscale-service.sh
	}
	environment = {
		HERDR_RELAY_ENV => $TAILSCALE_ENV
		PATH => $HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
		XPC_SERVICE_NAME => $TAILSCALE_LABEL
	}
	pid = 123
}
EOF
# Rendering produces a valid private LaunchAgent and quoted XML paths.
tailscale_render_unit > "$TAILSCALE_UNIT"
chmod 600 "$TAILSCALE_UNIT"
python3 - "$TAILSCALE_UNIT" <<'PY'
import plistlib,sys
p=plistlib.load(open(sys.argv[1],'rb'))
assert p['Label']=='com.herdr-mobile-relay.tailscale'
assert p['ProgramArguments'][0]=='/bin/bash'
assert p['Umask']==63 and p['RunAtLoad'] is True
assert p['KeepAlive']=={'SuccessfulExit':False}
assert 'HERDR_RELAY_TOKEN' not in p['EnvironmentVariables']
PY
tailscale_check_managed_unit
[[ "$(tailscale_service_state is-active "$TAILSCALE_LABEL")" == false ]]
tailscale_service start "$TAILSCALE_LABEL"
[[ "$(tailscale_service_pid)" == 123 ]]
[[ "$(tailscale_service_state is-enabled "$TAILSCALE_LABEL")" == true ]]
touch "$TEST_MAC/delayed-stop" "$TEST_MAC/fail-once"
tailscale_service restart "$TAILSCALE_LABEL"
[[ ! -e "$TEST_MAC/unloading" && ! -e "$TEST_MAC/fail-once" && -e "$TEST_MAC/loaded" ]]
rm "$TEST_MAC/delayed-stop"
tailscale_service stop "$TAILSCALE_LABEL"
[[ "$(tailscale_service_state is-active "$TAILSCALE_LABEL")" == false ]]
# Stop must not disable login startup; an update of a stopped job stays stopped.
[[ "$(tailscale_service_state is-enabled "$TAILSCALE_LABEL")" == true ]]
tailscale_service disable "$TAILSCALE_LABEL"
[[ "$(tailscale_service_state is-enabled "$TAILSCALE_LABEL")" == false ]]
if tailscale_service start "$TAILSCALE_LABEL"; then echo 'disabled job started' >&2; exit 1; fi
tailscale_service enable "$TAILSCALE_LABEL"
tailscale_service start "$TAILSCALE_LABEL"
# A cached replacement job is never stopped or overwritten just because the
# on-disk plist is still ours.
sed 's|program = /bin/bash|program = /bin/sh|' "$TEST_MAC/good" > "$TEST_MAC/cached"
before=$(wc -l < "$TEST_MAC/calls")
if tailscale_service stop "$TAILSCALE_LABEL"; then echo 'foreign job stopped' >&2; exit 1; fi
[[ -e "$TEST_MAC/loaded" ]]
if tail -n +"$((before+1))" "$TEST_MAC/calls" | grep -Eq '^(bootout|disable|bootstrap) '; then exit 1; fi
cp "$TEST_MAC/good" "$TEST_MAC/cached"
# No domain is an error, not an inactive service.
touch "$TEST_MAC/no-domain"
if tailscale_service_state is-active "$TAILSCALE_LABEL"; then exit 1; fi
rm "$TEST_MAC/no-domain"
# A Go child acquires the actual inherited descriptor; its exit leaves the
# lease held by the parent shell. A competing open description must fail.
relay_acquire_setup_lock "$TAILSCALE_CONFIG_DIR"
[[ "$HERDR_RELAY_SETUP_LOCK_FD" == 8 ]]
if (unset HERDR_RELAY_SETUP_LOCK_FD; exec 8>&-; relay_acquire_setup_lock "$TAILSCALE_CONFIG_DIR") 2>/dev/null; then echo 'competing Mac lifecycle lock accepted' >&2; exit 1; fi
relay_acquire_setup_lock "$TAILSCALE_CONFIG_DIR"
relay_drop_setup_lock "$TAILSCALE_CONFIG_DIR"
relay_acquire_setup_lock "$TAILSCALE_CONFIG_DIR"
relay_drop_setup_lock "$TAILSCALE_CONFIG_DIR"
# Snapshot and restore active/enabled intent through the private native hooks.
native_label="$TAILSCALE_LABEL" native_definition="$TAILSCALE_UNIT"
native_install_snapshot_activation
[[ "$native_active:$native_enabled" == true:true ]]
native_install_stop_for_restore
[[ ! -e "$TEST_MAC/loaded" ]]
native_install_restore_private_activation
[[ -e "$TEST_MAC/loaded" && ! -e "$TEST_MAC/disabled" ]]
tailscale_service stop "$TAILSCALE_LABEL"
tailscale_service disable "$TAILSCALE_LABEL"
native_install_snapshot_activation
[[ "$native_active:$native_enabled" == false:false ]]
native_install_restore_private_activation
[[ ! -e "$TEST_MAC/loaded" && -e "$TEST_MAC/disabled" ]]
# Restore a loaded-but-disabled job without losing its next-login override.
tailscale_service enable "$TAILSCALE_LABEL"
tailscale_service start "$TAILSCALE_LABEL"
tailscale_service disable "$TAILSCALE_LABEL"
native_install_snapshot_activation
[[ "$native_active:$native_enabled" == true:false ]]
if tailscale_service restart "$TAILSCALE_LABEL"; then exit 1; fi
[[ -e "$TEST_MAC/loaded" ]]
native_install_stop_for_restore
native_install_restore_private_activation
[[ -e "$TEST_MAC/loaded" && -e "$TEST_MAC/disabled" ]]
echo 'macOS private launchd adapter, drift guards, native restoration and inherited locking fixtures passed'
