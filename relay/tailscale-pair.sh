#!/usr/bin/env bash
# Private invitations: endpoint B and app origin A are independently checked.
set +x
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/tailscale-common.sh"
. "$SCRIPT_DIR/native-install-transaction.sh"
. "$SCRIPT_DIR/tailscale-transaction.sh"
APP_REQUEST='' CHOOSE=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app-origin) [ "$#" -ge 2 ] || exit 2; APP_REQUEST="$2"; shift ;;
        --choose-app) CHOOSE=true ;;
        *) echo 'Usage: tailscale-pair.sh [--choose-app | --app-origin PRIVATE_HTTPS_ORIGIN]' >&2; exit 2 ;;
    esac
    shift
done
[ -t 0 ] && [ -t 1 ] || { echo 'Private invitations require an attached private terminal; no invitation generated.' >&2; exit 1; }
unset GH_TOKEN GITHUB_TOKEN HERDR_RELAY_TOKEN HERDR_SESSION HERDR_CLIENT_SOCKET_PATH
tailscale_setup_context
TAILSCALE_BINARY="$(relay_binary)"
export HERDR_WEB_ROOT="$TAILSCALE_RELEASE_ROOT/current/web"
tailscale_acquire_setup_lock "$TAILSCALE_CONFIG_DIR"
tailscale_no_pending_update
for pending in "$TAILSCALE_CONFIG_DIR"/app-origin-recovery.*; do
    if [ -e "$pending" ] || [ -L "$pending" ]; then
        echo 'An interrupted app-origin change needs review. Preserve the private app-origin-recovery.* evidence, reconcile relay.env and restart the verified service before moving that evidence aside. No invitation generated.' >&2
        exit 1
    fi
done
TAILSCALE_HOST="$(tailscale_state_value hostname)"
TAILSCALE_HTTPS="$(tailscale_state_value https_port)"
TAILSCALE_PORT="$(tailscale_state_value relay_port)"
TAILSCALE_INSTANCE="$(tailscale_state_value instance)"
tailscale_pairing_ready
SAVED_APP="$(tailscale_env_value HERDR_PHONE_APP_URL)"
APP_ORIGIN="${SAVED_APP:-$TAILSCALE_ORIGIN}"
if [ "$CHOOSE" = true ] && [ -z "$APP_REQUEST" ]; then
    echo 'Keep this same app origin for every computer in the phone app.'
    echo 'The app-host computer must remain reachable to load/update the app; there is no automatic failover.'
    read -r -p "Private app origin [keep $APP_ORIGIN]: " APP_REQUEST || exit 1
fi
APP_ORIGIN="$("$TAILSCALE_BINARY" tailscale-pairing origin "${APP_REQUEST:-$APP_ORIGIN}")"
tailscale_app_ready "$APP_ORIGIN"
backup='' changed=false committed=false
cleanup_origin() {
    local code=$?
    trap - EXIT
    if [ "$changed" = true ] && [ "$committed" = false ]; then
        if cmp -s "$TAILSCALE_ENV" "$backup/new.env" && tailscale_check_managed_unit && tailscale_check_loaded_unit; then
            stage="$(mktemp "$TAILSCALE_CONFIG_DIR/.app-restore.XXXXXX")"
            if cp "$backup/old.env" "$stage" && chmod 600 "$stage" && mv -f "$stage" "$TAILSCALE_ENV" &&
               tailscale_service restart "$TAILSCALE_LABEL" && tailscale_pairing_ready; then
                echo 'Previous app configuration restored; existing device credentials were retained.' >&2
            else
                echo "App-origin recovery needs review; private evidence retained at $backup" >&2
                exit 1
            fi
        else
            echo "Configuration/service changed externally; preserving it and private recovery evidence at $backup" >&2
            exit 1
        fi
    fi
    [ -z "$backup" ] || rm -rf "$backup"
    exit "$code"
}
trap cleanup_origin EXIT
trap 'exit 130' INT TERM
if [ "$APP_ORIGIN" != "$SAVED_APP" ]; then
    before="$(tailscale_hash "$TAILSCALE_ENV")"
    echo "App origin: $APP_ORIGIN; relay endpoint remains $TAILSCALE_ORIGIN."
    echo 'Changing the app origin requires restarting this relay, not moving its Serve route or resetting credentials.'
    tailscale_confirm 'Save this app origin and restart the private service?'
    tailscale_pairing_ready
    tailscale_app_ready "$APP_ORIGIN"
    [ "$(tailscale_hash "$TAILSCALE_ENV")" = "$before" ] || { echo 'Configuration changed during approval.' >&2; exit 1; }
    backup="$(mktemp -d "$TAILSCALE_CONFIG_DIR/app-origin-recovery.XXXXXX")"
    cp "$TAILSCALE_ENV" "$backup/old.env"
    sed -E 's/^[[:space:]]*(export[[:space:]]+)?//' "$TAILSCALE_ENV" > "$backup/new.env"
    set_env_value_atomic "$backup/new.env" HERDR_PHONE_APP_URL "$APP_ORIGIN"
    # Keep this relay's own app usable without tightening authenticated shared
    # WebSocket access to only its hostname.
    origins="$(tailscale_env_value HERDR_ALLOWED_ORIGINS)"
    origins="${origins:-$TAILSCALE_ORIGIN}"
    case ",$origins," in *",$APP_ORIGIN,"*) ;; *) origins="$origins,$APP_ORIGIN" ;; esac
    set_env_value_atomic "$backup/new.env" HERDR_ALLOWED_ORIGINS "$origins"
    "$TAILSCALE_BINARY" tailscale-preflight environment "$backup/new.env"
    stage="$(mktemp "$TAILSCALE_CONFIG_DIR/.app-env.XXXXXX")"
    cp "$backup/new.env" "$stage"; chmod 600 "$stage"
    [ "$(tailscale_hash "$TAILSCALE_ENV")" = "$before" ] || exit 1
    changed=true
    mv -f "$stage" "$TAILSCALE_ENV"
    tailscale_service restart "$TAILSCALE_LABEL"
    tailscale_pairing_ready
    tailscale_app_ready "$APP_ORIGIN"
    committed=true
    rm -rf "$backup"
    backup=''
fi
# All checks precede arming. No invitation fragments are passed through shell
# variables, argv, metadata files, service logs or public app-host requests.
echo "Private app: $APP_ORIGIN"
echo "This relay: $TAILSCALE_ORIGIN"
echo 'The app host must stay reachable. Pairing one more phone does not revoke existing phones.'
PID="$(tailscale_service_pid)"
COLS="$(tput cols 2>/dev/null || printf 80)"
"$TAILSCALE_BINARY" tailscale-pairing show "$TAILSCALE_ENV" "$PID" "$APP_ORIGIN" "$TAILSCALE_ORIGIN" "$TAILSCALE_HOST" "$COLS"
relay_drop_setup_lock "$TAILSCALE_CONFIG_DIR"
read -r -p 'Keep this private display open while pairing; press Enter to dismiss.' _answer || true
