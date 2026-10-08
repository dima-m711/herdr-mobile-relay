#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Linux ]]; then echo 'Skipping Linux-only Tailscale context tests'; exit 0; fi
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-tailscale-context.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home space"
export HOME="$WORK/home space" TEST_OS=Linux TEST_ARCH=x86_64 TEST_UID=1000 TEST_BUS=ready TEST_CALLS="$WORK/calls"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME HERDR_RELEASE_ROOT HERDR_PLUGIN_CONFIG_DIR HERDR_RELAY_ENV HERDR_RELAY_BIN
cat > "$WORK/bin/uname" <<'STUB'
#!/bin/bash
case "$1" in -s) echo "$TEST_OS";; -m) echo "$TEST_ARCH";; *) exit 99;; esac
STUB
cat > "$WORK/bin/id" <<'STUB'
#!/bin/bash
[[ "$*" == -u ]] || exit 99
echo "$TEST_UID"
STUB
cat > "$WORK/bin/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_CALLS"
[[ "$*" == '--user show-environment' && "$TEST_BUS" == ready ]]
STUB
chmod 700 "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
source "$REPO_DIR/relay/common.sh"
source "$REPO_DIR/relay/tailscale-common.sh"
tailscale_setup_context
[[ "$TAILSCALE_ENV" == "$HOME/.config/herdr/plugins/config/herdr-mobile-relay.events/relay.env" ]]
[[ ! -e "$HOME/.config" && ! -e "$HOME/.local" ]]
tailscale_render_unit > "$WORK/unit"
grep -q '^UMask=0077$' "$WORK/unit"
grep -Fq "ExecStart=\"$HOME/.local/share/herdr-mobile-relay/current/relay/tailscale-service.sh\"" "$WORK/unit"
if grep -q 'cloudflared\|network-online' "$WORK/unit"; then echo 'unexpected startup dependency' >&2; exit 1; fi
for setting in 'TEST_OS=Darwin' 'TEST_ARCH=riscv64' 'TEST_UID=0' 'XDG_CONFIG_HOME=/custom' 'HERDR_RELEASE_ROOT=/custom' 'TEST_BUS=absent'; do
 if ( export "$setting"; tailscale_setup_context ) > "$WORK/output" 2> "$WORK/error"; then echo "unsafe context accepted: $setting" >&2; exit 1; fi
done
mkdir "$WORK/foreign"
ln -s "$WORK/foreign" "$HOME/.config"
if tailscale_setup_context > "$WORK/output" 2> "$WORK/error"; then echo 'symlink layout accepted' >&2; exit 1; fi
[[ ! -e "$WORK/foreign/herdr" ]]
if grep -Ev '^--user show-environment$' "$TEST_CALLS"; then echo 'preflight mutated a service' >&2; exit 1; fi
echo 'Tailscale context and unit rendering tests passed'
