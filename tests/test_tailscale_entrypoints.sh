#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux && "$(id -u)" != 0 ]] || { echo 'Skipping Linux user-service entrypoint fixtures'; exit 0; }
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-tailscale-entrypoints.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
go build -o "$WORK/helper" "$REPO_DIR/cmd/herdr-mobile-relay"
read -r TEST_PORT TEST_PLUGIN_PORT < <(python3 - <<'PY'
import socket
with socket.socket() as tcp, socket.socket(type=socket.SOCK_DGRAM) as udp:
    tcp.bind(('127.0.0.1', 0)); udp.bind(('127.0.0.1', 0))
    print(tcp.getsockname()[1], udp.getsockname()[1])
PY
)
export HOME="$WORK/home" TEST_CALLS="$WORK/calls" TEST_REPO="$REPO_DIR"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
unset HERDR_RELAY_ENV HERDR_PLUGIN_CONFIG_DIR HERDR_RELAY_BIN HERDR_RELEASE_ROOT HERDR_CONNECTION_MODE HERDR_RELAY_SERVICE_NAME HERDR_RELAY_SETUP_LOCK_FD
mkdir -p "$WORK/bin" "$HOME/.local/share/herdr-mobile-relay/current/relay" "$HOME/.config/systemd/user"
ln -s "$WORK/bin" "$HOME/.local/bin"
cp "$WORK/helper" "$HOME/.local/share/herdr-mobile-relay/current/herdr-mobile-relay"
cp "$REPO_DIR/relay/tailscale-service.sh" "$HOME/.local/share/herdr-mobile-relay/current/relay/"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_CALLS"
case "$*" in
 '--user show-environment') ;;
 '--user show herdr-mobile-relay-tailscale.service --property FragmentPath --value') echo "$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service" ;;
 '--user show herdr-mobile-relay-tailscale.service --property DropInPaths --value') ;;
 '--user restart herdr-mobile-relay-tailscale.service'|'--user start herdr-mobile-relay-tailscale.service'|'--user stop herdr-mobile-relay-tailscale.service') ;;
 *is-active*) exit 3 ;;
 *is-enabled*) exit 1 ;;
 *) exit 99 ;;
esac
STUB
for name in tailscale cloudflared sudo curl; do
 printf '#!/bin/bash\necho "%s" >> "$TEST_CALLS"\nexit 99\n' "$name" > "$WORK/bin/$name"
done
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/systemd-analyze"
cat > "$WORK/bin/herdr" <<'STUB'
#!/bin/bash
[[ "$*" == 'plugin uninstall herdr-mobile-relay.events' ]] || exit 99
printf 'plugin-unregistered\n' >> "$TEST_CALLS"
STUB
chmod 700 "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
. "$REPO_DIR/relay/common.sh"
. "$REPO_DIR/relay/tailscale-common.sh"
tailscale_setup_context
mkdir -p "$TAILSCALE_CONFIG_DIR"
chmod 700 "$TAILSCALE_CONFIG_DIR"
cat > "$TAILSCALE_ENV" <<EOF
HERDR_CONNECTION_MODE='tailscale'
HERDR_RELAY_TOKEN='0123456789abcdef0123456789abcdef'
HERDR_RELAY_INSTANCE_ID='fixture-instance'
HERDR_RELAY_PORT='$TEST_PORT'
HERDR_RELAY_PLUGIN_PORT='$TEST_PLUGIN_PORT'
HERDR_SOCKET_PATH='$HOME/.config/herdr/herdr.sock'
HERDR_RELAY_SERVICE_NAME='herdr-mobile-relay-tailscale.service'
HERDR_RELAY_HOST='127.0.0.1'
HERDR_GATEWAY_URL=''
HERDR_TRANSPORT_FORCE_RELAY='1'
HERDR_REACHABILITY_PORT_MAPPING='0'
HERDR_RELAY_REARM_BOOTSTRAP='0'
HERDR_RELEASE_ROOT='$TAILSCALE_RELEASE_ROOT'
HERDR_WEB_ROOT='$TAILSCALE_RELEASE_ROOT/current/web'
EOF
chmod 600 "$TAILSCALE_ENV"
tailscale_render_unit > "$TAILSCALE_UNIT"
chmod 600 "$TAILSCALE_UNIT"
"$WORK/helper" tailscale-state prepare "$TAILSCALE_STATE" mini.tailtest.ts.net 8443 "$TEST_PORT" "$TAILSCALE_ENV" "$TAILSCALE_UNIT" "$HOME/.config/herdr/herdr.sock" fixture-instance "$HOME/recovery" "$(printf 'a%.0s' {1..64})" adopted
for step in 'prepared local-ready' 'local-ready route-pending' 'route-pending route-ready' 'route-ready verified'; do
 "$WORK/helper" tailscale-state advance "$TAILSCALE_STATE" "${step%% *}" "${step#* }"
done
printf "  export   HERDR_CONNECTION_MODE='tailscale'\n  export   HERDR_RELAY_SERVICE_NAME='herdr-mobile-relay-tailscale.service'\n" > "$WORK/spaced.env"
[[ "$(relay_routing_setting "$WORK/spaced.env" HERDR_CONNECTION_MODE)" == tailscale ]]
[[ "$(relay_routing_setting "$WORK/spaced.env" HERDR_RELAY_SERVICE_NAME)" == herdr-mobile-relay-tailscale.service ]]
[[ "$(linux_relay_service_label)" == herdr-mobile-relay-tailscale.service ]]
[[ "$(installed_service_env_file)" == "$TAILSCALE_ENV" ]]
cp "$TAILSCALE_ENV" "$WORK/before.env"
: > "$TEST_CALLS"
bash "$REPO_DIR/relay/service.sh" restart > "$WORK/output" 2>&1
bash "$REPO_DIR/relay/start.sh" > "$WORK/output" 2>&1
bash "$REPO_DIR/relay/plugin-quick-start.sh" > "$WORK/output" 2>&1
cmp -s "$TAILSCALE_ENV" "$WORK/before.env"
grep -Fxq -- '--user restart herdr-mobile-relay-tailscale.service' "$TEST_CALLS"
if grep -Eq '^(tailscale|cloudflared|sudo|curl)$|restart herdr-mobile-relay.service' "$TEST_CALLS"; then echo 'private restart used wrong transport' >&2; exit 1; fi
: > "$TEST_CALLS"
bash "$REPO_DIR/relay/plugin-status.sh" > "$WORK/status" 2>&1
grep -Fq 'Phone authentication: not confirmed' "$WORK/status"
grep -Fq 'Private Serve endpoint: unavailable' "$WORK/status"
if grep -Eq '^(cloudflared|sudo)$|--user (start|restart|stop)' "$TEST_CALLS" || grep -q '0123456789abcdef' "$WORK/status"; then echo 'status mutated resources or disclosed a credential' >&2; exit 1; fi
for conflict in both malicious; do
 : > "$TEST_CALLS"
 if [[ "$conflict" == both ]]; then touch "$HOME/.config/systemd/user/herdr-mobile-relay.service"
 else export HERDR_RELAY_SERVICE_NAME=sshd.service; fi
 if bash "$REPO_DIR/relay/service.sh" restart > "$WORK/output" 2>&1; then echo "$conflict service choice accepted" >&2; exit 1; fi
 [[ ! -s "$TEST_CALLS" ]]
 rm -f "$HOME/.config/systemd/user/herdr-mobile-relay.service"
 unset HERDR_RELAY_SERVICE_NAME
done
: > "$TEST_CALLS"
if bash "$REPO_DIR/relay/rotate-token.sh" > "$WORK/output" 2>&1; then echo 'legacy rotation changed a private installation' >&2; exit 1; fi
cmp -s "$TAILSCALE_ENV" "$WORK/before.env"
if grep -q '0123456789abcdef' "$WORK/output"; then echo 'routing leaked a credential' >&2; exit 1; fi
: > "$TEST_CALLS"
if printf 'y\n' | bash "$REPO_DIR/relay/uninstall.sh" > "$WORK/output" 2>&1; then echo 'full uninstall removed an active private configuration' >&2; exit 1; fi
grep -Fq 'Run Tailscale teardown first' "$WORK/output"
[[ -f "$TAILSCALE_STATE" && -f "$TAILSCALE_UNIT" ]]
cmp -s "$TAILSCALE_ENV" "$WORK/before.env"
printf "HERDR_RELAY_SERVICE_NAME='sshd.service'\n" > "$TAILSCALE_ENV"
: > "$TEST_CALLS"
if bash "$REPO_DIR/relay/service.sh" restart > "$WORK/output" 2>&1; then echo 'stored malicious service name accepted' >&2; exit 1; fi
[[ ! -s "$TEST_CALLS" ]]
cp "$WORK/before.env" "$TAILSCALE_ENV"
# Every legacy entrypoint must reject private configuration before any service,
# HTTP, enrollment or deployment command, not merely fail at runtime afterward.
for script in plugin-choose-transport.sh plugin-install-service.sh stable-setup.sh stable-teardown.sh install-systemd-user-service.sh uninstall-systemd-user-service.sh install-service.sh uninstall-service.sh gateway-deploy.sh configure-app-deploy.sh change-hostname.sh herdr-mobile-relay-service.sh setup-link.sh plugin-setup-link.sh; do
 : > "$TEST_CALLS"
 if bash "$REPO_DIR/relay/$script" temporary < /dev/null > "$WORK/refusal" 2>&1; then echo "$script accepted private configuration" >&2; exit 1; fi
 [[ ! -s "$TEST_CALLS" ]]
 cmp -s "$TAILSCALE_ENV" "$WORK/before.env"
 [[ -f "$TAILSCALE_STATE" && -f "$TAILSCALE_UNIT" ]]
done
: > "$TEST_CALLS"
if HERDR_PLUGIN_CONFIG_DIR="$TAILSCALE_CONFIG_DIR" bash "$REPO_DIR/relay/plugin-build.sh" > "$WORK/refusal" 2>&1; then echo 'legacy plugin build accepted private configuration' >&2; exit 1; fi
grep -Fq 'Private installation detected' "$WORK/refusal"
! grep -Eq 'systemctl.*(restart|enable|disable|stop)|tailscale serve --' "$TEST_CALLS"
cmp -s "$TAILSCALE_ENV" "$WORK/before.env"
# A nested mutation must reuse the same descriptor, not deadlock or bypass it.
(
 relay_acquire_setup_lock "$TAILSCALE_CONFIG_DIR"
 bash "$REPO_DIR/relay/service.sh" restart > "$WORK/output" 2>&1
 env -u HERDR_RELAY_SETUP_LOCK_FD bash "$REPO_DIR/relay/service.sh" restart > "$WORK/contender" 2>&1 && exit 99
 exit 0
)
# An unknown standard wrapper cannot redirect discovery into executable env
# contents, even if the manager would claim that its service is active.
FOREIGN_HOME="$WORK/foreign-home"
mkdir -p "$FOREIGN_HOME/.config/systemd/user"
printf 'touch "%s/env-executed"\nexit 99\n' "$WORK" > "$FOREIGN_HOME/evil.env"
printf '[Service]\nEnvironment="HERDR_RELAY_ENV=%s/evil.env"\nExecStart="/unknown/wrapper"\n' "$FOREIGN_HOME" > "$FOREIGN_HOME/.config/systemd/user/herdr-mobile-relay.service"
chmod 600 "$FOREIGN_HOME/.config/systemd/user/herdr-mobile-relay.service"
if HOME="$FOREIGN_HOME" bash "$REPO_DIR/relay/start.sh" > "$WORK/output" 2>&1; then echo 'unknown standard wrapper accepted' >&2; exit 1; fi
[[ ! -e "$WORK/env-executed" ]]
grep -Fq 'Unrecognized standard service definition' "$WORK/output"
# Full deletion is distinct from teardown. It may remove retained data only
# after teardown, ownership/sentinel checks and a second explicit confirmation.
"$WORK/helper" tailscale-state advance "$TAILSCALE_STATE" verified teardown-pending
"$WORK/helper" tailscale-state advance "$TAILSCALE_STATE" teardown-pending removed
rm "$TAILSCALE_UNIT"
for root in "$TAILSCALE_RELEASE_ROOT" "$TAILSCALE_CONFIG_DIR"; do
 printf 'product=herdr-mobile-relay\nroot=%s\n' "$root" > "$root/.herdr-mobile-relay-installation"
 chmod 600 "$root/.herdr-mobile-relay-installation"
done
cp "$TAILSCALE_STATE" "$WORK/removed-adopted.json"
"$WORK/helper" tailscale-state retry "$TAILSCALE_STATE" "$HOME/new-recovery" "$(printf 'a%.0s' {1..64})" absent
for step in 'prepared local-ready' 'local-ready route-pending'; do
 "$WORK/helper" tailscale-state advance "$TAILSCALE_STATE" "${step%% *}" "${step#* }"
done
"$WORK/helper" tailscale-state advance "$TAILSCALE_STATE" route-pending route-ready created
for step in 'route-ready verified' 'verified teardown-pending' 'teardown-pending removed'; do
 "$WORK/helper" tailscale-state advance "$TAILSCALE_STATE" "${step%% *}" "${step#* }"
done
# A created endpoint cannot be confirmed absent while the client is unavailable.
if printf 'y\n' | bash "$REPO_DIR/relay/uninstall.sh" > "$WORK/output" 2>&1; then echo 'unverified created endpoint allowed credential deletion' >&2; exit 1; fi
cmp -s "$TAILSCALE_ENV" "$WORK/before.env"
cp "$WORK/removed-adopted.json" "$TAILSCALE_STATE"
printf 'n\n' | bash "$REPO_DIR/relay/uninstall.sh" > "$WORK/output" 2>&1
grep -Fq 'Cancelled.' "$WORK/output"
cmp -s "$TAILSCALE_ENV" "$WORK/before.env"
: > "$TEST_CALLS"
printf 'y\n' | bash "$REPO_DIR/relay/uninstall.sh" > "$WORK/output" 2>&1
[[ ! -e "$TAILSCALE_ENV" && ! -e "$TAILSCALE_RELEASE_ROOT" ]]
grep -Fxq 'plugin-unregistered' "$TEST_CALLS"
if grep -Eq '^(tailscale|cloudflared|sudo|curl)$|--user (start|restart|stop|disable)' "$TEST_CALLS"; then echo 'post-teardown deletion changed adopted routes or services' >&2; exit 1; fi
echo 'Tailscale entrypoint and service selection tests passed'
