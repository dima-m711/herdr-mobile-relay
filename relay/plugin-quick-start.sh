#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
if [ -n "${HERDR_BIN_PATH:-}" ]; then
    export HERDR_BIN="$HERDR_BIN_PATH"
fi

. "$SCRIPT_DIR/common.sh"
ENV_FILE="$(relay_env_path "$SCRIPT_DIR")"
CONNECTION_MODE="$(relay_connection_mode "$ENV_FILE")"
if [ "$CONNECTION_MODE" = tailscale ]; then
    exec bash "$SCRIPT_DIR/start.sh"
fi
DEFAULT_SETUP="$(relay_default_setup "$ENV_FILE")"
if [ "$DEFAULT_SETUP" = tailscale ]; then exec bash "$SCRIPT_DIR/tailscale-setup.sh"; fi
relay_require_legacy_transport "$ENV_FILE"
assert_selected_relay_definition "$ENV_FILE"

echo "🐑 Herdr Mobile Relay plugin setup"
echo ""
echo "This pane installs missing user-level tools, creates private plugin"
echo "configuration, and starts a relay with a phone setup QR code. It uses"
echo "whichever connection method the chooser configured: the community"
echo "gateway, your own gateway, or a Cloudflare tunnel."
echo ""

"$SCRIPT_DIR/setup.sh" --install-missing
exec "$SCRIPT_DIR/start.sh"
