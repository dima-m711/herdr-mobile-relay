#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/tailscale-common.sh"
. "$SCRIPT_DIR/native-install-transaction.sh"
. "$SCRIPT_DIR/tailscale-transaction.sh"
TAILSCALE_SUDO=false TAILSCALE_KEEP_ROUTE=false ADOPT=false RECOVER=false NO_PAIR=false PORT_EXPLICIT=false
TAILSCALE_HTTPS=8443
APP_OVERRIDE='' BOOTSTRAP_RELEASE='' BOOTSTRAP_PREVIOUS=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --https-port) [ "$#" -ge 2 ] || exit 2; TAILSCALE_HTTPS="$2"; PORT_EXPLICIT=true; shift ;;
        --sudo) TAILSCALE_SUDO=true ;;
        --adopt-runbook) ADOPT=true ;;
        --recover) RECOVER=true ;;
        --keep-route) TAILSCALE_KEEP_ROUTE=true ;;
        --no-pair) NO_PAIR=true ;;
        --release-directory) [ "$#" -ge 2 ] || exit 2; BOOTSTRAP_RELEASE="$2"; shift ;;
        --app-origin) [ "$#" -ge 2 ] || exit 2; APP_OVERRIDE="$2"; shift ;;
        --help|-h)
            echo 'Usage: tailscale-setup.sh [--https-port PORT] [--adopt-runbook] [--sudo] [--no-pair] [--app-origin PRIVATE_HTTPS_ORIGIN]'
            echo '       tailscale-setup.sh --recover [--keep-route] [--sudo]'
            echo 'Initial runbook adoption may add --release-directory VERIFIED_STAGED_BUNDLE (also usable with --recover).'
            echo 'Run in a private terminal. Tailscale must already be installed and connected.'
            exit 0 ;;
        *) echo 'Unknown Tailscale setup option.' >&2; exit 2 ;;
    esac
    shift
done
[ "$TAILSCALE_KEEP_ROUTE" = false ] || [ "$RECOVER" = true ] || exit 2
[ -t 0 ] && [ -t 1 ] || { echo 'Tailscale setup requires your private interactive terminal; nothing changed.' >&2; exit 1; }
unset GH_TOKEN GITHUB_TOKEN HERDR_GITHUB_TOKEN_FILE HERDR_RELAY_TOKEN HERDR_SESSION HERDR_CLIENT_SOCKET_PATH
tailscale_setup_context
export HERDR_RELAY_ENV="$TAILSCALE_ENV" HERDR_RELEASE_ROOT="$TAILSCALE_RELEASE_ROOT"
export HERDR_WEB_ROOT="$TAILSCALE_RELEASE_ROOT/current/web"
TAILSCALE_BINARY="$(relay_binary)"
if [ -n "$BOOTSTRAP_RELEASE" ]; then
    [ "$ADOPT" = true ] || [ "$RECOVER" = true ] || { echo 'A staged release is only for explicit initial runbook adoption/recovery.' >&2; exit 2; }
    [ "$(realpath -e "$BOOTSTRAP_RELEASE")" = "$BOOTSTRAP_RELEASE" ] &&
        [ "$(dirname "$BOOTSTRAP_RELEASE")" = "$TAILSCALE_RELEASE_ROOT/releases" ] &&
        [ "$SCRIPT_DIR" = "$BOOTSTRAP_RELEASE/relay" ] || { echo 'Run the verified staged bundle setup script from the managed releases directory.' >&2; exit 1; }
    TAILSCALE_BINARY="$BOOTSTRAP_RELEASE/herdr-mobile-relay"
    "$TAILSCALE_BINARY" verify-release --connection-mode tailscale "$BOOTSTRAP_RELEASE" >/dev/null
    export HERDR_RELAY_BIN="$TAILSCALE_BINARY"
    [ -L "$TAILSCALE_RELEASE_ROOT/current" ] || { echo 'Initial adoption requires the existing release symlink.' >&2; exit 1; }
    BOOTSTRAP_PREVIOUS="$(realpath -e "$TAILSCALE_RELEASE_ROOT/current")"
    [ "$(dirname "$BOOTSTRAP_PREVIOUS")" = "$TAILSCALE_RELEASE_ROOT/releases" ] || exit 1
    "$BOOTSTRAP_PREVIOUS/herdr-mobile-relay" verify-release "$BOOTSTRAP_PREVIOUS" >/dev/null
fi
if [ -n "$APP_OVERRIDE" ]; then APP_OVERRIDE="$("$TAILSCALE_BINARY" tailscale-pairing origin "$APP_OVERRIDE")"; fi
[ -x "${BOOTSTRAP_RELEASE:-$TAILSCALE_RELEASE_ROOT/current}/relay/tailscale-service.sh" ] || { echo 'Install a verified fork bundle with Tailscale support before setup.' >&2; exit 1; }
tailscale_no_other_services
PHASE='' OLD_RECOVERY='' SOURCE_ENV=''
if [ -e "$TAILSCALE_STATE" ] || [ -L "$TAILSCALE_STATE" ]; then
    PHASE="$(tailscale_state_value phase)"
    saved_port="$(tailscale_state_value https_port)"
    if [ "$PORT_EXPLICIT" = true ] && [ "$TAILSCALE_HTTPS" != "$saved_port" ]; then echo 'Changing an existing endpoint requires a separate migration.' >&2; exit 1; fi
    TAILSCALE_HTTPS="$saved_port"
    TAILSCALE_HOST="$(tailscale_state_value hostname)"
    TAILSCALE_PORT="$(tailscale_state_value relay_port)"
    TAILSCALE_INSTANCE="$(tailscale_state_value instance)"
    TAILSCALE_SOCKET="$(tailscale_state_value socket)"
    tailscale_check_state_identity
    tailscale_acquire_setup_lock "$TAILSCALE_CONFIG_DIR"
    tailscale_no_pending_update
    PHASE="$(tailscale_state_value phase)"
    if [ "$RECOVER" = true ]; then tailscale_recover; exit $?; fi
    case "$PHASE" in
        verified)
            [ -z "$BOOTSTRAP_RELEASE" ] || { echo 'This setup is already managed; use its private updater.' >&2; exit 1; }
            [ "$(tailscale_hostname)" = "$TAILSCALE_HOST" ] || { echo 'Tailscale hostname changed; app-origin migration requires review.' >&2; exit 1; }
            tailscale_check_managed_unit || { echo 'Managed unit changed; refusing automatic replacement.' >&2; exit 1; }
            tailscale_check_loaded_unit
            "$TAILSCALE_BINARY" tailscale-preflight managed-environment "$TAILSCALE_ENV" "$TAILSCALE_STATE" "$TAILSCALE_RELEASE_ROOT"
            tailscale_read_serve
            [ "$TAILSCALE_ROUTE_STATE" = matching ] || { echo 'Saved private route is missing; inspect it before recovery.' >&2; exit 1; }
            tailscale_local_ready
            tailscale_https_ready
            if [ -n "$APP_OVERRIDE" ] && [ "$APP_OVERRIDE" != "$(tailscale_env_value HERDR_PHONE_APP_URL)" ]; then
                echo 'Use the private pairing app-origin action to review an existing app-origin change.' >&2; exit 1
            fi
            echo 'Private relay is verified; existing identity and pairings are unchanged.'
            if [ "$NO_PAIR" = false ]; then exec bash "$SCRIPT_DIR/tailscale-pair.sh"; fi
            exit 0 ;;
        rolled-back)
            OLD_RECOVERY="$(tailscale_state_value recovery_directory)"
            [ "$(dirname "$OLD_RECOVERY")" = "$HOME/.local/state/herdr-mobile-relay/recovery" ] || exit 1
            SOURCE_ENV="$OLD_RECOVERY/new.env" ;;
        removed)
            [ -f "$TAILSCALE_ENV" ] && [ ! -e "$TAILSCALE_UNIT" ] && [ ! -L "$TAILSCALE_UNIT" ] &&
                [ "$(native_systemd_state is-active "$TAILSCALE_LABEL")" = false ] && [ "$(native_systemd_state is-enabled "$TAILSCALE_LABEL")" = false ] || {
                echo 'A completed teardown must retain its environment and have no remaining service before setup can resume.' >&2; exit 1;
            }
            "$TAILSCALE_BINARY" tailscale-preflight managed-environment "$TAILSCALE_ENV" "$TAILSCALE_STATE" "$TAILSCALE_RELEASE_ROOT" ;;
        *) echo 'Setup is incomplete. Run this command with --recover; retained private evidence will be used, not overwritten.' >&2; exit 1 ;;
    esac
elif [ "$RECOVER" = true ]; then echo 'No saved Tailscale setup is available for recovery.' >&2; exit 1; fi
TAILSCALE_HOST="$(tailscale_hostname)"
if [ -n "$PHASE" ]; then tailscale_check_state_identity; fi
if [ -e "$TAILSCALE_ENV" ] || [ -L "$TAILSCALE_ENV" ]; then SOURCE_ENV="$TAILSCALE_ENV"; fi
TAILSCALE_PORT=8375 TAILSCALE_PLUGIN_PORT=8376
if [ -n "$SOURCE_ENV" ]; then
    "$TAILSCALE_BINARY" tailscale-preflight environment "$SOURCE_ENV"
    token="$(tailscale_env_value HERDR_RELAY_TOKEN "$SOURCE_ENV")"
    [ "${#token}" -eq 32 ] || { echo 'Existing configuration lacks a valid key; refusing to regenerate credentials.' >&2; exit 1; }
    unset token
    TAILSCALE_PORT="$(tailscale_env_value HERDR_RELAY_PORT "$SOURCE_ENV")"; TAILSCALE_PORT="${TAILSCALE_PORT:-8375}"
    TAILSCALE_PLUGIN_PORT="$(tailscale_env_value HERDR_RELAY_PLUGIN_PORT "$SOURCE_ENV")"; TAILSCALE_PLUGIN_PORT="${TAILSCALE_PLUGIN_PORT:-8376}"
    TAILSCALE_INSTANCE="$(tailscale_env_value HERDR_RELAY_INSTANCE_ID "$SOURCE_ENV")"
    [ -n "$TAILSCALE_INSTANCE" ] || { echo 'Existing relay identity is missing; manual review required.' >&2; exit 1; }
    for setting in "HERDR_RELEASE_ROOT=$TAILSCALE_RELEASE_ROOT" "HERDR_RELAY_ENV=$TAILSCALE_ENV" "HERDR_PLUGIN_CONFIG_DIR=$TAILSCALE_CONFIG_DIR" "HERDR_WEB_ROOT=$HERDR_WEB_ROOT"; do
        persisted="$(tailscale_env_value "${setting%%=*}" "$SOURCE_ENV")"
        [ -z "$persisted" ] || [ "$persisted" = "${setting#*=}" ] || { echo 'Stored custom paths require manual migration; no changes made.' >&2; exit 1; }
    done
    [ -z "$(tailscale_env_value HERDR_GATEWAY_URL "$SOURCE_ENV")" ] || { echo 'Existing gateway configuration requires explicit transport migration, not automatic replacement.' >&2; exit 1; }
    [ -z "$(tailscale_env_value GH_TOKEN "$SOURCE_ENV")$(tailscale_env_value GITHUB_TOKEN "$SOURCE_ENV")" ] || { echo 'Migrate raw release credentials to a private token file before adoption.' >&2; exit 1; }
    saved_socket="$(tailscale_env_value HERDR_SOCKET_PATH "$SOURCE_ENV")"
    TAILSCALE_SOCKET="${saved_socket:-${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}}"
    selected_bin="$(tailscale_env_value HERDR_BIN "$SOURCE_ENV")"
else
    for orphan in "$TAILSCALE_CONFIG_DIR/device-auth" "$TAILSCALE_CONFIG_DIR/.env"; do
        [ ! -e "$orphan" ] && [ ! -L "$orphan" ] || { echo 'Identity data exists without relay.env; recover the original credentials first.' >&2; exit 1; }
    done
    TAILSCALE_SOCKET="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}"
    selected_bin=''
fi
selected_bin="${selected_bin:-${HERDR_BIN:-$(type -P herdr || true)}}"
case "$HOME:$selected_bin:$TAILSCALE_SOCKET" in *"'"*) echo 'Single quotes in selected paths are unsupported by the environment writer; nothing changed.' >&2; exit 1 ;; esac
"$TAILSCALE_BINARY" tailscale-preflight session "$selected_bin" "$TAILSCALE_SOCKET"
if [ -z "$SOURCE_ENV" ] && ! command -v openssl >/dev/null && ! command -v uuidgen >/dev/null; then
    echo 'Install openssl or uuidgen before creating a new relay identity.' >&2; exit 1
fi
tailscale_read_serve
BEFORE_STATE="$TAILSCALE_ROUTE_STATE" BEFORE_DIGEST="$TAILSCALE_DIGEST"
UNIT_EXISTED=false
SOURCE_DIGEST=''
[ -z "$SOURCE_ENV" ] || SOURCE_DIGEST="$(sha256sum "$SOURCE_ENV")"
if [ -e "$TAILSCALE_UNIT" ] || [ -L "$TAILSCALE_UNIT" ]; then
    UNIT_EXISTED=true
    [ "$ADOPT" = true ] || { echo 'Existing Tailscale unit requires --adopt-runbook and explicit review.' >&2; exit 1; }
    "$TAILSCALE_BINARY" tailscale-preflight runbook "$TAILSCALE_UNIT" "$TAILSCALE_CONFIG_DIR/start-tailscale-relay.sh"
    [ -n "$SOURCE_ENV" ] && [ "$BEFORE_STATE" = matching ] || { echo 'Runbook adoption requires its private environment and matching Serve route.' >&2; exit 1; }
    tailscale_check_loaded_unit
    tailscale_existing_ready
else
    [ "$BEFORE_STATE" = absent ] || [ "$PHASE" = rolled-back ] || [ "$PHASE" = removed ] || { echo 'An existing route has no recognized relay identity; review it manually before adoption.' >&2; exit 1; }
    [ "$(native_systemd_state is-active "$TAILSCALE_LABEL")" = false ] || { echo 'An active Tailscale service has no recognized definition.' >&2; exit 1; }
    "$TAILSCALE_BINARY" tailscale-preflight ports "$TAILSCALE_PORT" "$TAILSCALE_PLUGIN_PORT"
fi
[ -z "$BOOTSTRAP_RELEASE" ] || [ "$UNIT_EXISTED" = true ] || { echo 'Staged bootstrap requires the recognized existing runbook unit.' >&2; exit 1; }
app='' origins=''
if [ -n "$SOURCE_ENV" ]; then
    app="$(tailscale_env_value HERDR_PHONE_APP_URL "$SOURCE_ENV")"
    origins="$(tailscale_env_value HERDR_ALLOWED_ORIGINS "$SOURCE_ENV")"
fi
if [ -z "$APP_OVERRIDE" ] && [ -z "$app" ] && [ "$NO_PAIR" = false ]; then
    echo 'For another computer in the same phone app, enter the existing private app origin.'
    read -r -p "Private app origin [this host: $TAILSCALE_ORIGIN]: " APP_OVERRIDE || exit 1
fi
APP_ORIGIN="$("$TAILSCALE_BINARY" tailscale-pairing origin "${APP_OVERRIDE:-${app:-$TAILSCALE_ORIGIN}}")"
if [ "$APP_ORIGIN" != "$TAILSCALE_ORIGIN" ]; then tailscale_app_ready "$APP_ORIGIN"; fi
origins="${origins:-$TAILSCALE_ORIGIN}"
case ",$origins," in *",$APP_ORIGIN,"*) ;; *) origins="$origins,$APP_ORIGIN" ;; esac
echo "Phone app origin: $APP_ORIGIN (must remain reachable; no automatic app-host failover)."
printf 'Private endpoint: %s -> %s\nSelected Herdr socket: %s\n' "$TAILSCALE_ORIGIN" "$TAILSCALE_TARGET" "$TAILSCALE_SOCKET"
echo 'Install the Tailscale-only user service; preserve existing credentials/device-auth and unrelated Serve routes.'
echo 'Enforce loopback, Tailscale mode, empty gateway, forced relay transport, no port mapping and no bootstrap reset.'
if [ "$UNIT_EXISTED" = true ]; then
    echo 'Adoption changes ExecStart from start-tailscale-relay.sh to the packaged current/relay/tailscale-service.sh.'
    echo 'The original unit/environment (including permissions) will be retained in a private recovery directory.'
fi
echo 'HTTPS certificates disclose the machine and tailnet DNS names in public certificate-transparency logs.'
echo 'The service starts at login. Unattended boot also requires separately approved linger and a running Herdr session.'
if [ "$BEFORE_STATE" = matching ]; then echo 'The matching existing route will be adopted, never removed by automatic rollback.'
else echo "Configure: tailscale serve --bg --https=$TAILSCALE_HTTPS $TAILSCALE_TARGET"; echo "If this attempt fails, remove only its still-matching created route: tailscale serve --https=$TAILSCALE_HTTPS off"; fi
[ "$TAILSCALE_SUDO" = false ] || echo 'The listed scoped Serve commands will use sudo in this terminal; no operator, ACL, Funnel or linger changes.'
if [ -n "$BOOTSTRAP_RELEASE" ]; then
    echo "Also stop the recognized runbook service and activate $BOOTSTRAP_RELEASE; rollback retains/restores $BOOTSTRAP_PREVIOUS."
fi
tailscale_confirm
tailscale_validate_directories
mkdir -p "$TAILSCALE_CONFIG_DIR" "$TAILSCALE_UNIT_DIR"
chmod 700 "$TAILSCALE_CONFIG_DIR"
tailscale_acquire_setup_lock "$TAILSCALE_CONFIG_DIR"
tailscale_no_pending_update
if [ -z "$PHASE" ]; then
    [ ! -e "$TAILSCALE_STATE" ] && [ ! -L "$TAILSCALE_STATE" ] || { echo 'Another setup attempt appeared during approval; inspect it before retrying.' >&2; exit 1; }
else
    [ "$(tailscale_state_value phase)" = "$PHASE" ] || { echo 'Setup phase changed during approval; aborting.' >&2; exit 1; }
fi
# Reinspect after approval/lock acquisition, before the first resource mutation.
tailscale_no_other_services
if [ -z "$SOURCE_ENV" ]; then
    for appeared in "$TAILSCALE_ENV" "$TAILSCALE_CONFIG_DIR/device-auth" "$TAILSCALE_CONFIG_DIR/.env"; do
        [ ! -e "$appeared" ] && [ ! -L "$appeared" ] || { echo 'Identity data appeared during approval; refusing to replace it.' >&2; exit 1; }
    done
fi
tailscale_read_serve
[ "$TAILSCALE_ROUTE_STATE" = "$BEFORE_STATE" ] && [ "$TAILSCALE_DIGEST" = "$BEFORE_DIGEST" ] || { echo 'Serve changed during approval; aborting without replacement.' >&2; exit 1; }
if [ -n "$SOURCE_ENV" ]; then
    "$TAILSCALE_BINARY" tailscale-preflight environment "$SOURCE_ENV"
    [ "$(sha256sum "$SOURCE_ENV")" = "$SOURCE_DIGEST" ] || { echo 'Configuration changed during approval; aborting.' >&2; exit 1; }
fi
if [ "$UNIT_EXISTED" = true ]; then
    "$TAILSCALE_BINARY" tailscale-preflight runbook "$TAILSCALE_UNIT" "$TAILSCALE_CONFIG_DIR/start-tailscale-relay.sh"
else
    [ ! -e "$TAILSCALE_UNIT" ] && [ ! -L "$TAILSCALE_UNIT" ] || { echo 'A unit appeared during approval; aborting.' >&2; exit 1; }
fi
if [ -n "$BOOTSTRAP_RELEASE" ]; then
    [ -L "$TAILSCALE_RELEASE_ROOT/current" ] && [ "$(realpath -e "$TAILSCALE_RELEASE_ROOT/current")" = "$BOOTSTRAP_PREVIOUS" ] || { echo 'Release changed during approval.' >&2; exit 1; }
    "$TAILSCALE_BINARY" verify-release --connection-mode tailscale "$BOOTSTRAP_RELEASE" >/dev/null
fi
native_keep_recovery=true
native_install_begin systemd "$TAILSCALE_UNIT" '' "$TAILSCALE_ENV" "$TAILSCALE_LABEL" ''
if [ "$ADOPT" = true ] && [ "$native_previous_ready" != true ]; then
    echo 'Cannot retain verified previous readiness for runbook rollback; no adoption performed.' >&2
    exit 1
fi
if [ -n "$BOOTSTRAP_RELEASE" ]; then
    printf '%s\n' "$BOOTSTRAP_PREVIOUS" > "$native_recovery/previous-release"
    printf '%s\n' "$BOOTSTRAP_RELEASE" > "$native_recovery/candidate-release"
    sync -f "$native_recovery"
fi
STAGED_ENV="$native_recovery/new.env"
if [ -n "$SOURCE_ENV" ]; then
    cp -p "$SOURCE_ENV" "$STAGED_ENV"
    "$TAILSCALE_BINARY" tailscale-preflight environment "$STAGED_ENV"
    # Canonicalize assignment prefixes so existing exported/indented settings
    # are replaced rather than duplicated by the shared atomic setters.
    sed -e 's/^[[:space:]]*//' -e 's/^export //' "$STAGED_ENV" > "$native_recovery/canonical.env"
    mv "$native_recovery/canonical.env" "$STAGED_ENV"
fi
ensure_relay_env "$STAGED_ENV"
for assignment in 'HERDR_CONNECTION_MODE tailscale' 'HERDR_RELAY_HOST 127.0.0.1' 'HERDR_TRANSPORT_FORCE_RELAY 1' 'HERDR_REACHABILITY_PORT_MAPPING 0' 'HERDR_RELAY_REARM_BOOTSTRAP 0'; do
    set_env_value_atomic "$STAGED_ENV" "${assignment%% *}" "${assignment#* }"
done
set_env_value_atomic "$STAGED_ENV" HERDR_GATEWAY_URL ''
set_env_value_atomic "$STAGED_ENV" HERDR_RELAY_PORT "$TAILSCALE_PORT"
set_env_value_atomic "$STAGED_ENV" HERDR_RELAY_PLUGIN_PORT "$TAILSCALE_PLUGIN_PORT"
set_env_value_atomic "$STAGED_ENV" HERDR_BIN "$selected_bin"
set_env_value_atomic "$STAGED_ENV" HERDR_SOCKET_PATH "$TAILSCALE_SOCKET"
set_env_value_atomic "$STAGED_ENV" HERDR_RELEASE_ROOT "$TAILSCALE_RELEASE_ROOT"
set_env_value_atomic "$STAGED_ENV" HERDR_WEB_ROOT "$HERDR_WEB_ROOT"
set_env_value_atomic "$STAGED_ENV" HERDR_PHONE_APP_URL "$APP_ORIGIN"
set_env_value_atomic "$STAGED_ENV" HERDR_ALLOWED_ORIGINS "$origins"
set_env_value_atomic "$STAGED_ENV" HERDR_RELAY_SERVICE_NAME "$TAILSCALE_LABEL"
TAILSCALE_INSTANCE="$(tailscale_env_value HERDR_RELAY_INSTANCE_ID "$STAGED_ENV")"
route=absent; [ "$BEFORE_STATE" != matching ] || route=adopted
if [ "$PHASE" = rolled-back ] || [ "$PHASE" = removed ]; then
    [ "$(tailscale_state_value instance)" = "$TAILSCALE_INSTANCE" ] && [ "$(tailscale_state_value socket)" = "$TAILSCALE_SOCKET" ] && [ "$(tailscale_state_value relay_port)" = "$TAILSCALE_PORT" ] || exit 1
    "$TAILSCALE_BINARY" tailscale-state retry "$TAILSCALE_STATE" "$native_recovery" "$TAILSCALE_DIGEST" "$route"
else
    "$TAILSCALE_BINARY" tailscale-state prepare "$TAILSCALE_STATE" "$TAILSCALE_HOST" "$TAILSCALE_HTTPS" "$TAILSCALE_PORT" "$TAILSCALE_ENV" "$TAILSCALE_UNIT" "$TAILSCALE_SOCKET" "$TAILSCALE_INSTANCE" "$native_recovery" "$TAILSCALE_DIGEST" "$route"
fi
tailscale_render_unit > "$native_recovery/new.service"
chmod 600 "$native_recovery/new.service"
if [ -n "$BOOTSTRAP_RELEASE" ]; then
    # The old current bundle has no private launcher. Validate against the
    # staged physical release first, without changing the final unit template.
    tailscale_render_unit "$BOOTSTRAP_RELEASE" > "$native_recovery/new-validation.service"
    chmod 600 "$native_recovery/new-validation.service"
    systemd-analyze --user verify "$native_recovery/new-validation.service"
else
    systemd-analyze --user verify "$native_recovery/new.service"
fi
if [ -n "$BOOTSTRAP_RELEASE" ]; then
    [ -L "$TAILSCALE_RELEASE_ROOT/current" ] && [ "$(realpath -e "$TAILSCALE_RELEASE_ROOT/current")" = "$BOOTSTRAP_PREVIOUS" ] &&
        cmp -s "$TAILSCALE_ENV" "$native_recovery/2" && cmp -s "$TAILSCALE_UNIT" "$native_recovery/0" || { echo 'Bootstrap identity changed before cutover; preserving it.' >&2; exit 1; }
fi
native_changed=true
if [ -n "$BOOTSTRAP_RELEASE" ]; then
    systemctl --user stop "$TAILSCALE_LABEL"
    "$TAILSCALE_BINARY" activate-release "$TAILSCALE_RELEASE_ROOT" "$BOOTSTRAP_RELEASE"
    # Now the final current-based launcher exists; verify the exact unit before
    # publishing it. Failure still follows the guarded old-release rollback.
    systemd-analyze --user verify "$native_recovery/new.service"
fi
native_stage="$(mktemp "$TAILSCALE_CONFIG_DIR/.relay-env.XXXXXX")"
cp "$STAGED_ENV" "$native_stage"; chmod 600 "$native_stage"; mv -f "$native_stage" "$TAILSCALE_ENV"
native_stage="$(mktemp "$TAILSCALE_UNIT_DIR/.herdr-tailscale.XXXXXX")"
cp "$native_recovery/new.service" "$native_stage"; chmod 600 "$native_stage"; mv -f "$native_stage" "$TAILSCALE_UNIT"
systemctl --user daemon-reload
tailscale_check_loaded_unit
"$TAILSCALE_BINARY" tailscale-preflight managed-environment "$TAILSCALE_ENV" "$TAILSCALE_STATE" "$TAILSCALE_RELEASE_ROOT"
systemctl --user enable "$TAILSCALE_LABEL"
systemctl --user restart "$TAILSCALE_LABEL"
tailscale_local_ready
"$TAILSCALE_BINARY" tailscale-state advance "$TAILSCALE_STATE" prepared local-ready
# Approvals do not authorize overwriting a concurrently changed endpoint.
tailscale_read_serve
[ "$TAILSCALE_ROUTE_STATE" = "$BEFORE_STATE" ] && [ "$TAILSCALE_DIGEST" = "$BEFORE_DIGEST" ] || exit 1
"$TAILSCALE_BINARY" tailscale-state advance "$TAILSCALE_STATE" local-ready route-pending
if [ "$BEFORE_STATE" = absent ]; then tailscale_change_route create; route=created; fi
tailscale_read_serve
[ "$TAILSCALE_ROUTE_STATE" = matching ] && [ "$TAILSCALE_DIGEST" = "$BEFORE_DIGEST" ] || { echo 'Post-change Serve ownership verification failed; retaining recovery evidence.' >&2; exit 1; }
"$TAILSCALE_BINARY" tailscale-state advance "$TAILSCALE_STATE" route-pending route-ready "$route"
tailscale_https_ready
"$TAILSCALE_BINARY" tailscale-state advance "$TAILSCALE_STATE" route-ready verified
native_install_commit
echo 'Private HTTPS and relay identity verified. Phone authentication has not been confirmed.'
echo 'Existing pairing data was preserved. Generate an invitation only in your private terminal.'
unset HERDR_RELAY_BIN
if [ "$NO_PAIR" = false ]; then exec bash "$SCRIPT_DIR/tailscale-pair.sh"; fi
