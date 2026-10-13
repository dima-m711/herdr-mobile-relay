#!/usr/bin/env bash
# Persistent Tailscale mode: start only the relay. HTTPS routing belongs to the
# approved setup transaction, never normal service startup or network recovery.
set +x
set -euo pipefail
unset GH_TOKEN GITHUB_TOKEN HERDR_RELAY_BIN
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

ENV_FILE="$(relay_env_file "$SCRIPT_DIR")"
if ! private_owned_file "$ENV_FILE"; then
    echo 'Tailscale relay requires an owned mode-0600 environment file without links.' >&2
    exit 78
fi
# The service always executes its own bundle, never a manager-environment
# binary override. Validate static data before shell sourcing, even on restart.
RELAY_BIN="$(dirname "$SCRIPT_DIR")/herdr-mobile-relay"
[ -x "$RELAY_BIN" ] || { echo 'The packaged relay executable is missing.' >&2; exit 78; }
[ "$("$RELAY_BIN" tailscale-preflight environment "$ENV_FILE" HERDR_CONNECTION_MODE)" = tailscale ] || {
    echo 'The service requires an explicit Tailscale mode in its validated environment.' >&2
    exit 78
}
load_relay_env "$ENV_FILE"
set +x
unset GH_TOKEN GITHUB_TOKEN HERDR_RELAY_BIN HERDR_SESSION HERDR_CLIENT_SOCKET_PATH
if [ "${HERDR_CONNECTION_MODE:-}" != tailscale ]; then
    echo 'Tailscale service requires explicit Tailscale mode; refusing transport fallback.' >&2
    exit 78
fi

relay_drop_setup_lock "$(dirname "$ENV_FILE")"
case "$(uname -s)" in
    Darwin)
        export HERDR_RELAY_SERVICE_NAME=com.herdr-mobile-relay.tailscale
        # launchd has no journal. Keep runtime diagnostics in the private config
        # directory; invitations are never rendered by this launcher.
        LOG_FILE="$(dirname "$ENV_FILE")/tailscale-relay.log"
        if [ ! -e "$LOG_FILE" ] && [ ! -L "$LOG_FILE" ]; then (umask 077; set -C; : > "$LOG_FILE") || exit 78; fi
        private_owned_file "$LOG_FILE" || exit 78
        exec 9>>"$LOG_FILE"
        "$RELAY_BIN" tailscale-platform check-fd 9 "$LOG_FILE" || exit 78
        exec 1>&9 2>&9 9>&-
        ;;
    Linux) export HERDR_RELAY_SERVICE_NAME=herdr-mobile-relay-tailscale.service ;;
    *) exit 78 ;;
esac
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# The runtime validates the private transport policy. Do not silently repair
# unsafe settings, rotate keys, regenerate an instance, or rearm bootstrap.
exec "$RELAY_BIN" serve
