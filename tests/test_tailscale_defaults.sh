#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-private-defaults.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" XDG_DATA_HOME="$WORK/home/.local/share" XDG_STATE_HOME="$WORK/home/.local/state" XDG_CACHE_HOME="$WORK/home/.cache"
unset HERDR_RELAY_ENV HERDR_RELAY_BIN HERDR_PLUGIN_CONFIG_DIR HERDR_RELEASE_ROOT HERDR_RELAY_SETUP_LOCK_FD HERDR_CONNECTION_MODE HERDR_RELAY_SERVICE_NAME HERDR_LEGACY_SETUP HERDR_DEV_TUNNEL HERDR_GATEWAY_URL CLOUDFLARED_CONFIG
export TEST_ACTIONS="$WORK/actions" TEST_NETWORK="$WORK/network" TEST_SYSTEM=Linux
mkdir -p "$HOME/.local/bin" "$WORK/relay"
cp "$REPO_DIR/relay/"{common,setup,start,service,plugin-quick-start,plugin-setup-menu}.sh "$WORK/relay/"
for name in tailscale-setup tailscale-teardown tailscale-control plugin-choose-transport; do
 printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >> "$TEST_ACTIONS"\n' "$name" > "$WORK/relay/$name.sh"
 chmod 700 "$WORK/relay/$name.sh"
done
cat > "$HOME/.local/bin/uname" <<'STUB'
#!/bin/bash
if [[ "${1:-}" == -s ]]; then echo "$TEST_SYSTEM"; else /usr/bin/uname "$@"; fi
STUB
for name in curl tailscale cloudflared systemctl launchctl sudo herdr; do
 printf '#!/bin/bash\necho "%s" >> "$TEST_NETWORK"\nexit 99\n' "$name" > "$HOME/.local/bin/$name"
done
chmod 700 "$HOME/.local/bin/"*
export PATH="$HOME/.local/bin:$PATH"
for script in setup start plugin-quick-start; do
 bash "$WORK/relay/$script.sh" > "$WORK/output" 2>&1
 [[ "$(tail -1 "$TEST_ACTIONS")" == 'tailscale-setup ' ]]
done
bash "$WORK/relay/service.sh" install > "$WORK/output" 2>&1
[[ "$(tail -1 "$TEST_ACTIONS")" == 'tailscale-setup ' ]]
printf '\nq\n' | bash "$WORK/relay/plugin-setup-menu.sh" > "$WORK/menu" 2>&1
grep -Fq 'Tailscale Private Setup (recommended)' "$WORK/menu"
[[ "$(tail -1 "$TEST_ACTIONS")" == 'tailscale-setup ' ]]
[[ ! -e "$WORK/relay/.env" && ! -e "$TEST_NETWORK" ]]
# Rendering private setup does not execute environment text or health probes.
printf "HERDR_CONNECTION_MODE='tailscale'\ntouch '%s/unsafe-source'\n" "$WORK" > "$WORK/relay/.env"
printf 'a\nr\nt\np\nq\n' | bash "$WORK/relay/plugin-setup-menu.sh" > "$WORK/menu" 2>&1
for expected in 'tailscale-setup --adopt-runbook' 'tailscale-setup --recover' 'tailscale-teardown ' 'tailscale-control restart'; do grep -Fxq "$expected" "$TEST_ACTIONS"; done
[[ ! -e "$WORK/unsafe-source" && ! -e "$TEST_NETWORK" ]]
. "$WORK/relay/common.sh"
printf "HERDR_GATEWAY_URL='wss://gateway.example.test'\n" > "$WORK/relay/.env"
[[ "$(relay_default_setup "$WORK/relay/.env")" == legacy ]]
rm "$WORK/relay/.env"
HERDR_LEGACY_SETUP=1; [[ "$(relay_default_setup "$WORK/relay/.env")" == legacy ]]; unset HERDR_LEGACY_SETUP
HERDR_GATEWAY_URL=wss://explicit.example.test; [[ "$(relay_default_setup "$WORK/relay/.env")" == legacy ]]; unset HERDR_GATEWAY_URL
relay_record_connection_method "$WORK/relay/.env" temporary
[[ "$(relay_default_setup "$WORK/relay/.env")" == legacy ]]
relay_record_connection_method "$WORK/relay/.env" unselected
[[ "$(relay_default_setup "$WORK/relay/.env")" == tailscale ]]
# macOS keeps its existing default and has no private-service setup action.
export TEST_SYSTEM=Darwin
printf '\nq\n' | bash "$WORK/relay/plugin-setup-menu.sh" > "$WORK/mac-menu" 2>&1
[[ "$(tail -1 "$TEST_ACTIONS")" == 'plugin-choose-transport temporary' ]]
if grep -q 'Tailscale Private Setup' "$WORK/mac-menu"; then echo 'Linux-only menu shown on macOS' >&2; exit 1; fi
# macOS's legacy status probes are fake and may run; private/fresh Linux never did.
echo 'Tailscale default and menu tests passed'
