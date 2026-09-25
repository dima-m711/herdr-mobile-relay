#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"
require_user_service_context
ENV_FILE="$(relay_env_path "$SCRIPT_DIR")"
relay_require_legacy_transport "$ENV_FILE" migration

LABELS=("herdr-mobile-relay.service" "herdr-remote.service")

for label in "${LABELS[@]}"; do
    systemctl --user disable --now "$label" >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/$label"
done
systemctl --user daemon-reload

echo "Stopped and removed Herdr Mobile Relay services"
