#!/usr/bin/env bash
# Persistent Tailscale mode: start only the relay. HTTPS routing belongs to the
# approved setup transaction, never normal service startup or network recovery.
set +x
set -euo pipefail
unset GH_TOKEN GITHUB_TOKEN
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

ENV_FILE="$(relay_env_file "$SCRIPT_DIR")"
if ! private_owned_file "$ENV_FILE"; then
    echo 'Tailscale relay requires an owned mode-0600 environment file without links.' >&2
    exit 78
fi
load_relay_env "$ENV_FILE"
set +x
unset GH_TOKEN GITHUB_TOKEN HERDR_SESSION HERDR_CLIENT_SOCKET_PATH
if [ "${HERDR_CONNECTION_MODE:-}" != tailscale ]; then
    echo 'Tailscale service requires explicit Tailscale mode; refusing transport fallback.' >&2
    exit 78
fi

export HERDR_RELAY_SERVICE_NAME=herdr-mobile-relay-tailscale.service
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
RELAY_BIN="$(relay_binary)"
# The runtime validates the private transport policy. Do not silently repair
# unsafe settings, rotate keys, regenerate an instance, or rearm bootstrap.
exec "$RELAY_BIN" serve
