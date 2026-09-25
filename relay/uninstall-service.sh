#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"
require_user_service_context
ENV_FILE="$(relay_env_path "$SCRIPT_DIR")"
relay_require_legacy_transport "$ENV_FILE" migration

LABELS=("com.herdr-mobile-relay.service" "com.herdr-remote.service")

for label in "${LABELS[@]}"; do
    plist="$HOME/Library/LaunchAgents/$label.plist"
    launchctl bootout "gui/$UID" "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
done

echo "Stopped and removed Herdr Mobile Relay services"
