#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACTION="${1:-}"
. "$SCRIPT_DIR/common.sh"
require_supported_platform
case "$ACTION" in
    install|uninstall|start|restart|stop|status|logs) ;;
    *) echo "Usage: $0 {install|uninstall|start|restart|stop|status|logs}"; exit 2 ;;
esac
ENV_FILE="$(relay_env_path "$SCRIPT_DIR")"
MODE="$(relay_connection_mode "$ENV_FILE")"
if [ "$MODE" = tailscale ]; then
    case "$ACTION" in
        install) exec bash "$SCRIPT_DIR/tailscale-setup.sh" ;;
        uninstall) exec bash "$SCRIPT_DIR/tailscale-teardown.sh" ;;
        *) exec bash "$SCRIPT_DIR/tailscale-control.sh" "$ACTION" ;;
    esac
fi
case "$(uname -s)" in
    Darwin)
        case "$ACTION" in
            install) exec "$SCRIPT_DIR/install-service.sh" ;;
            uninstall) exec "$SCRIPT_DIR/uninstall-service.sh" ;;
            start|restart) exec launchctl kickstart -k "gui/$(id -u)/com.herdr-mobile-relay.service" ;;
            stop) exec launchctl kill SIGTERM "gui/$(id -u)/com.herdr-mobile-relay.service" ;;
            status) exec launchctl print "gui/$(id -u)/com.herdr-mobile-relay.service" ;;
            logs) exec tail -f "$HOME/Library/Logs/herdr-mobile-relay/service.log" "$HOME/Library/Logs/herdr-mobile-relay/service.err" ;;
        esac ;;
    Linux)
        LABEL="$(linux_relay_service_label)"
        case "$ACTION" in
            status) exec systemctl --user status "$LABEL" ;;
            logs) exec journalctl --user -u "$LABEL" -f ;;
        esac
        relay_require_legacy_transport "$ENV_FILE"
        case "$ACTION" in
            install) exec "$SCRIPT_DIR/install-systemd-user-service.sh" ;;
            uninstall) exec "$SCRIPT_DIR/uninstall-systemd-user-service.sh" ;;
            start|restart|stop)
                assert_linux_relay_unit "$LABEL" "$ENV_FILE"
                exec systemctl --user "$ACTION" "$LABEL" ;;
        esac ;;
esac
