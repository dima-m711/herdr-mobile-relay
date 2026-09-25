#!/usr/bin/env bash
# Runtime control never provisions Serve, rotates pairing state or selects a
# fallback transport. Setup/teardown are separate interactive operations.
set +x
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/tailscale-common.sh"
. "$SCRIPT_DIR/native-install-transaction.sh"
. "$SCRIPT_DIR/tailscale-transaction.sh"
ACTION="${1:-status}"
case "$ACTION" in start|restart|stop|status|logs) ;; *) echo 'Unsupported Tailscale service action.' >&2; exit 2 ;; esac
ENV_FILE="$(relay_env_file "$SCRIPT_DIR")"
[ "$(relay_connection_mode "$ENV_FILE")" = tailscale ] || { echo 'No Tailscale installation is selected.' >&2; exit 1; }
unset GH_TOKEN GITHUB_TOKEN HERDR_RELAY_TOKEN HERDR_SESSION HERDR_CLIENT_SOCKET_PATH
tailscale_setup_context
TAILSCALE_BINARY="$(relay_binary)"
export HERDR_WEB_ROOT="$TAILSCALE_RELEASE_ROOT/current/web"
if [ ! -e "$TAILSCALE_STATE" ] && [ ! -L "$TAILSCALE_STATE" ]; then
    echo 'Tailscale service is not yet managed. Review it with tailscale-setup.sh --adopt-runbook; no service was changed.' >&2
    exit 1
fi
tailscale_acquire_setup_lock "$TAILSCALE_CONFIG_DIR"
PHASE="$(tailscale_state_value phase)"
TAILSCALE_HOST="$(tailscale_state_value hostname)"
TAILSCALE_HTTPS="$(tailscale_state_value https_port)"
TAILSCALE_PORT="$(tailscale_state_value relay_port)"
TAILSCALE_INSTANCE="$(tailscale_state_value instance)"
tailscale_check_state_identity
if [ "$ACTION" = status ]; then
    printf 'Connection mode: Tailscale only\nSetup phase: %s\nService: %s\n' "$PHASE" "$TAILSCALE_LABEL"
    echo 'Phone authentication: not confirmed by these diagnostics.'
fi
[ "$PHASE" = verified ] || { echo 'Setup/teardown is incomplete or removed. Use the Tailscale setup/recovery action; no fallback was started.' >&2; exit 1; }
tailscale_no_other_services
tailscale_check_managed_unit || { echo 'Unrecognized managed unit; refusing automatic service control.' >&2; exit 1; }
tailscale_check_loaded_unit
"$TAILSCALE_BINARY" tailscale-preflight managed-environment "$TAILSCALE_ENV" "$TAILSCALE_STATE" "$TAILSCALE_RELEASE_ROOT"
case "$ACTION" in
    start|restart|stop)
        systemctl --user "$ACTION" "$TAILSCALE_LABEL"
        echo "Tailscale service $ACTION requested. Use Status for readiness; no network configuration or pairing data changed."
        ;;
    logs)
        # A log viewer is not a mutator and must not block subsequent setup.
        relay_drop_setup_lock "$TAILSCALE_CONFIG_DIR"
        exec journalctl --user -u "$TAILSCALE_LABEL" -f
        ;;
    status)
        ready=false
        if TAILSCALE_HEALTH="$(wait_for_relay_health "$TAILSCALE_PORT" 1 0 "$TAILSCALE_INSTANCE")"; then
            pid="$(systemctl --user show "$TAILSCALE_LABEL" --property MainPID --value)"
            if "$TAILSCALE_BINARY" tailscale-preflight listener "$pid" "$TAILSCALE_PORT" "$TAILSCALE_BINARY"; then ready=true; fi
        fi
        echo "Local release/instance/listener verified: $ready"
        if [ "$(tailscale_hostname)" = "$TAILSCALE_HOST" ] && tailscale_read_serve && [ "$TAILSCALE_ROUTE_STATE" = matching ]; then
            echo "Private Serve endpoint: $TAILSCALE_ORIGIN (matching configuration)"
            if [ "$ready" = true ] && tailscale_https_ready; then echo 'Private HTTPS identity: verified'
            else echo 'Private HTTPS identity: unavailable or unverified; no transport fallback.'; fi
        else echo 'Private Serve endpoint: unavailable, changed or unverified; check Tailscale connectivity and ACLs.'; fi
        ;;
esac
