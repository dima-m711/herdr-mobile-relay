#!/usr/bin/env bash
# Explicit departure only after teardown; never remove or recreate a route here.
set +x
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/tailscale-common.sh"
. "$SCRIPT_DIR/native-install-transaction.sh"
. "$SCRIPT_DIR/tailscale-transaction.sh"
METHOD="${1:-}"
case "$METHOD" in temporary|stable|community|own) ;; *) echo 'Choose temporary, stable, community or own explicitly.' >&2; exit 2 ;; esac
[ -t 0 ] && [ -t 1 ] || { echo 'Transport switching requires your private interactive terminal.' >&2; exit 1; }
unset GH_TOKEN GITHUB_TOKEN HERDR_RELAY_TOKEN
tailscale_setup_context
TAILSCALE_BINARY="$(relay_binary)"
tailscale_acquire_setup_lock "$TAILSCALE_CONFIG_DIR"
tailscale_no_pending_update
TAILSCALE_HOST="$(tailscale_state_value hostname)"
TAILSCALE_HTTPS="$(tailscale_state_value https_port)"
TAILSCALE_PORT="$(tailscale_state_value relay_port)"
tailscale_verify_removed
before="$(tailscale_hash "$TAILSCALE_ENV")"
echo "Leave Tailscale-only mode and select $METHOD explicitly?"
echo 'The selected alternative may use public infrastructure. No automatic fallback is being enabled.'
echo 'Credentials, device-auth, app origin and recovery evidence remain. Temporary app origins may require new enrollment.'
echo 'If this computer hosted the private app, choose a reachable app origin separately.'
tailscale_confirm 'Approve leaving private-only mode?'
tailscale_verify_removed
[ "$(tailscale_hash "$TAILSCALE_ENV")" = "$before" ] || { echo 'Configuration changed during approval; nothing changed.' >&2; exit 1; }
stage="$(umask 077; mktemp "$TAILSCALE_CONFIG_DIR/.transport-env.XXXXXX")"
trap 'rm -f "$stage"' EXIT
# Normalize accepted static prefixes before replacing selectors. Keep secrets
# in the private staged file, not shell variables or command arguments.
sed -E 's/^[[:space:]]*(export[[:space:]]+)?//' "$TAILSCALE_ENV" > "$stage"
set_env_value_atomic "$stage" HERDR_CONNECTION_MODE ''
set_env_value_atomic "$stage" HERDR_RELAY_SERVICE_NAME ''
"$TAILSCALE_BINARY" tailscale-preflight environment "$stage"
# If interrupted before the atomic env commit, private mode still wins. After
# commit, the explicit intent is already durable and cannot look like a new host.
relay_record_connection_method "$TAILSCALE_ENV" "$METHOD"
[ "$(tailscale_hash "$TAILSCALE_ENV")" = "$before" ] || exit 1
mv -f "$stage" "$TAILSCALE_ENV"
trap - EXIT
echo 'Private-only selectors cleared after verified teardown. No service or network resource was changed.'
