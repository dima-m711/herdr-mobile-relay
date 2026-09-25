#!/usr/bin/env bash
# Private update cutover: configuration, unit, pairing data and Serve are read-only.
set +x
set -euo pipefail
umask 077
DOWNLOAD_TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
export -n DOWNLOAD_TOKEN
unset GH_TOKEN GITHUB_TOKEN HERDR_RELAY_TOKEN HERDR_SESSION HERDR_CLIENT_SOCKET_PATH
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/tailscale-common.sh"
. "$SCRIPT_DIR/native-install-transaction.sh"
. "$SCRIPT_DIR/tailscale-transaction.sh"
VERSION=${1:-}
[[ "$#" = 1 && "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo 'Usage: tailscale-update.sh MAJOR.MINOR.PATCH' >&2; exit 2; }
[ "${HERDR_RELEASE_REPOSITORY:-dima-m711/herdr-mobile-relay}" = dima-m711/herdr-mobile-relay ] || { echo 'Private updates require this fork release repository.' >&2; exit 1; }
EXPECTED_REVISION=${HERDR_UPDATE_EXPECTED_REVISION:-}
[[ -z "$EXPECTED_REVISION" || "$EXPECTED_REVISION" =~ ^[0-9a-f]{40}$ ]] || exit 2
tailscale_setup_context
tailscale_acquire_setup_lock "$TAILSCALE_CONFIG_DIR"
tailscale_no_pending_update
for pending in "$TAILSCALE_CONFIG_DIR"/app-origin-recovery.*; do
    [ ! -e "$pending" ] && [ ! -L "$pending" ] || { echo 'Review the interrupted app-origin change before updating.' >&2; exit 1; }
done
[ -L "$TAILSCALE_RELEASE_ROOT/current" ] || { echo 'Private updates require a managed current release symlink.' >&2; exit 1; }
PREVIOUS="$(realpath -e "$TAILSCALE_RELEASE_ROOT/current")"
[ "$(dirname "$PREVIOUS")" = "$TAILSCALE_RELEASE_ROOT/releases" ] || { echo 'Current release is outside the managed release directory.' >&2; exit 1; }
TAILSCALE_BINARY="$PREVIOUS/herdr-mobile-relay"
export HERDR_RELAY_BIN="$TAILSCALE_BINARY" HERDR_WEB_ROOT="$PREVIOUS/web"
"$TAILSCALE_BINARY" verify-release --connection-mode tailscale "$PREVIOUS" >/dev/null
TAILSCALE_HOST="$(tailscale_state_value hostname)"
TAILSCALE_HTTPS="$(tailscale_state_value https_port)"
TAILSCALE_PORT="$(tailscale_state_value relay_port)"
TAILSCALE_INSTANCE="$(tailscale_state_value instance)"
[ "$(tailscale_state_value phase)" = verified ] || { echo 'Complete private setup/recovery before updating.' >&2; exit 1; }
ACTIVE="$(native_systemd_state is-active "$TAILSCALE_LABEL")"
ENABLED="$(native_systemd_state is-enabled "$TAILSCALE_LABEL")"
check_definition() {
    tailscale_check_state_identity && tailscale_no_other_services && tailscale_check_managed_unit && tailscale_check_loaded_unit || return 1
    "$TAILSCALE_BINARY" tailscale-preflight managed-environment "$TAILSCALE_ENV" "$TAILSCALE_STATE" "$TAILSCALE_RELEASE_ROOT" || return 1
    [ "$(tailscale_hostname)" = "$TAILSCALE_HOST" ] || return 1
    tailscale_read_serve || return 1
    [ "$TAILSCALE_ROUTE_STATE" = matching ] || { echo 'Private endpoint changed; no update cutover.' >&2; return 1; }
    [ "$(native_systemd_state is-enabled "$TAILSCALE_LABEL")" = "$ENABLED" ]
}
check_runtime() {
    if [ "$ACTIVE" = true ]; then
        [ "$(native_systemd_state is-active "$TAILSCALE_LABEL")" = true ] && tailscale_local_ready && tailscale_https_ready
    else
        [ "$(native_systemd_state is-active "$TAILSCALE_LABEL")" = false ] &&
            "$TAILSCALE_BINARY" tailscale-preflight ports "$TAILSCALE_PORT" "$(tailscale_env_value HERDR_RELAY_PLUGIN_PORT)"
    fi
}
check_definition
check_runtime
BEFORE="$(sha256sum "$TAILSCALE_ENV" "$TAILSCALE_UNIT" "$TAILSCALE_STATE")"
# The repository installer is staging-only here. It must not be replaced by
# a legacy installer override that could ignore the no-activation contract.
INSTALLER="$SCRIPT_DIR/../install.sh"
[ -f "$INSTALLER" ] && [ ! -L "$INSTALLER" ] || exit 1
CANDIDATE="$(GH_TOKEN="$DOWNLOAD_TOKEN" INSTALL_ROOT="$TAILSCALE_RELEASE_ROOT" HERDR_RELEASE_REPOSITORY=dima-m711/herdr-mobile-relay HERDR_RELEASE_STAGE_ONLY=1 HERDR_RELEASE_REQUIRED_MODE=tailscale sh "$INSTALLER" "$VERSION")"
unset DOWNLOAD_TOKEN
[[ "$CANDIDATE" != *$'\n'* && "$CANDIDATE" = /* ]] || { echo 'Invalid staged release path.' >&2; exit 1; }
[ "$(realpath -e "$CANDIDATE")" = "$CANDIDATE" ] && [ "$(dirname "$CANDIDATE")" = "$TAILSCALE_RELEASE_ROOT/releases" ] || exit 1
verify_args=(--connection-mode tailscale --version "$VERSION")
[ -z "$EXPECTED_REVISION" ] || verify_args+=(--revision "$EXPECTED_REVISION")
"$CANDIDATE/herdr-mobile-relay" verify-release "${verify_args[@]}" "$CANDIDATE" >/dev/null
[ "$(realpath -e "$TAILSCALE_RELEASE_ROOT/current")" = "$PREVIOUS" ] &&
    [ "$(sha256sum "$TAILSCALE_ENV" "$TAILSCALE_UNIT" "$TAILSCALE_STATE")" = "$BEFORE" ] || { echo 'Release or configuration changed while staging; cutover refused.' >&2; exit 1; }
check_definition
check_runtime
if [ "$CANDIDATE" = "$PREVIOUS" ]; then echo 'Private release already verified; no restart or invitation performed.'; exit 0; fi
RECOVERY="$(mktemp -d "$TAILSCALE_CONFIG_DIR/update-recovery.XXXXXX")"
{
    printf 'previous=%s\ncandidate=%s\nactive=%s\nenabled=%s\n' "$PREVIOUS" "$CANDIDATE" "$ACTIVE" "$ENABLED"
    printf '%s\n' "$BEFORE"
} > "$RECOVERY/identity"
sync -f "$RECOVERY/identity"
CUTOVER=false
cleanup_update() {
    local result=$?
    trap - EXIT
    if [ "$result" -ne 0 ] && [ "$CUTOVER" = true ]; then
        echo 'Private update failed; checking whether rollback is still safe.' >&2
        if [ -L "$TAILSCALE_RELEASE_ROOT/current" ] &&
           [ "$(realpath -e "$TAILSCALE_RELEASE_ROOT/current")" = "$CANDIDATE" ] &&
           [ "$(sha256sum "$TAILSCALE_ENV" "$TAILSCALE_UNIT" "$TAILSCALE_STATE")" = "$BEFORE" ] &&
           { [ "$ACTIVE" = true ] || [ "$(native_systemd_state is-active "$TAILSCALE_LABEL")" = false ]; } && check_definition &&
           "$PREVIOUS/herdr-mobile-relay" verify-release --connection-mode tailscale "$PREVIOUS" >/dev/null &&
           "$PREVIOUS/herdr-mobile-relay" activate-release "$TAILSCALE_RELEASE_ROOT" "$PREVIOUS"; then
            TAILSCALE_BINARY="$PREVIOUS/herdr-mobile-relay"
            export HERDR_RELAY_BIN="$TAILSCALE_BINARY" HERDR_WEB_ROOT="$PREVIOUS/web"
            if { [ "$ACTIVE" = false ] || systemctl --user restart "$TAILSCALE_LABEL"; } && check_runtime; then
                echo 'Previous private release recovered; configuration and pairings were not replaced.' >&2
            else
                echo "Rollback restart/verification failed; private evidence retained at $RECOVERY" >&2
                exit 1
            fi
        else
            echo "Rollback refused after identity drift; private evidence retained at $RECOVERY" >&2
            exit 1
        fi
    fi
    rm -rf "$RECOVERY"
    exit "$result"
}
trap cleanup_update EXIT
trap 'exit 130' INT TERM
# Write-ahead evidence survives SIGKILL/power loss. Ambiguous interruptions are
# never silently replayed; an owner must reconcile the pointer/service first.
CUTOVER=true
"$CANDIDATE/herdr-mobile-relay" activate-release "$TAILSCALE_RELEASE_ROOT" "$CANDIDATE"
TAILSCALE_BINARY="$CANDIDATE/herdr-mobile-relay"
export HERDR_RELAY_BIN="$TAILSCALE_BINARY" HERDR_WEB_ROOT="$CANDIDATE/web"
if [ "$ACTIVE" = true ]; then systemctl --user restart "$TAILSCALE_LABEL"; fi
[ -L "$TAILSCALE_RELEASE_ROOT/current" ] && [ "$(realpath -e "$TAILSCALE_RELEASE_ROOT/current")" = "$CANDIDATE" ] &&
    [ "$(sha256sum "$TAILSCALE_ENV" "$TAILSCALE_UNIT" "$TAILSCALE_STATE")" = "$BEFORE" ] && check_definition && check_runtime || exit 1
CUTOVER=false
echo 'Private release updated and verified. Service enablement, credentials, app origin and Serve were preserved; no invitation was armed.'
