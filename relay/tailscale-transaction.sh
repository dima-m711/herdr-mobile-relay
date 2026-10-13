#!/usr/bin/env bash
# Source common.sh, tailscale-common.sh and native-install-transaction.sh first.
set +x

tailscale_no_pending_update() {
    local evidence
    for evidence in "$TAILSCALE_CONFIG_DIR"/update-recovery.*; do
        if [ -e "$evidence" ] || [ -L "$evidence" ]; then
            echo 'Interrupted private update requires owner review. Preserve update-recovery.* evidence, reconcile current and the verified service, then move evidence aside before another lifecycle change or invitation.' >&2
            return 1
        fi
    done
}

tailscale_state_value() { "$TAILSCALE_BINARY" tailscale-state get "$TAILSCALE_STATE" "$1"; }
tailscale_env_value() { "$TAILSCALE_BINARY" tailscale-preflight environment "${2:-$TAILSCALE_ENV}" "$1"; }
tailscale_read_serve() {
    local inspection
    inspection="$(tailscale_serve_inspect "$TAILSCALE_HOST" "$TAILSCALE_HTTPS" "$TAILSCALE_PORT")" || return 1
    IFS=$'\t' read -r TAILSCALE_ROUTE_STATE TAILSCALE_ORIGIN TAILSCALE_TARGET TAILSCALE_DIGEST <<< "$inspection"
}

tailscale_confirm() {
    local answer
    [ -t 0 ] && [ -t 1 ] || { echo 'Run this operation in your private interactive terminal; no changes made.' >&2; return 1; }
    read -r -p "${1:-Approve these changes?} [y/N] " answer || return 1
    case "$answer" in y|Y|yes|YES) return 0 ;; *) echo 'Cancelled; no new changes approved.' >&2; return 1 ;; esac
}

tailscale_check_managed_unit() {
    private_owned_file "${1:-$TAILSCALE_UNIT}" || return 1
    cmp -s "${1:-$TAILSCALE_UNIT}" <(tailscale_render_unit)
}

tailscale_no_other_services() {
    local other
    local labels='herdr-mobile-relay.service herdr-remote.service' suffix=''
    if [ "${TAILSCALE_MANAGER:-systemd}" = launchd ]; then labels='com.herdr-mobile-relay.service com.herdr-remote.service'; suffix=.plist; fi
    for other in $labels; do
        if [ -e "$TAILSCALE_UNIT_DIR/$other$suffix" ] || [ -L "$TAILSCALE_UNIT_DIR/$other$suffix" ] ||
           [ "$(tailscale_service_state is-active "$other")" = true ] || [ "$(tailscale_service_state is-enabled "$other")" = true ]; then
            echo 'Another relay service exists. Review and remove the conflict explicitly before changing transport.' >&2
            return 1
        fi
    done
}

tailscale_check_loaded_unit() {
    if [ "${TAILSCALE_MANAGER:-systemd}" = launchd ]; then tailscale_darwin_check_loaded; return; fi
    local fragment overrides
    fragment="$(timeout 10 systemctl --user show "$TAILSCALE_LABEL" --property FragmentPath --value)" || return 1
    overrides="$(timeout 10 systemctl --user show "$TAILSCALE_LABEL" --property DropInPaths --value)" || return 1
    [ "$fragment" = "$TAILSCALE_UNIT" ] && [ -z "$overrides" ] || {
        echo 'Unrecognized systemd fragment or overrides; refusing service mutation.' >&2
        return 1
    }
}

tailscale_check_state_identity() {
    [ "$(tailscale_state_value environment)" = "$TAILSCALE_ENV" ] &&
    [ "$(tailscale_state_value unit)" = "$TAILSCALE_UNIT" ] &&
    [ "$(tailscale_state_value hostname)" = "$TAILSCALE_HOST" ] &&
    [ "$(tailscale_state_value https_port)" = "$TAILSCALE_HTTPS" ] || {
        echo 'Saved setup identity differs from this machine/configuration; manual migration review required.' >&2
        return 1
    }
}

# Shared precondition for explicit transport departure and full data removal.
# A terminal record alone never authorizes changing a newly active resource.
tailscale_verify_removed() {
    [ "$(tailscale_state_value phase)" = removed ] || { echo 'Complete Tailscale teardown before changing transport or deleting data.' >&2; return 1; }
    tailscale_check_state_identity || return 1
    tailscale_no_other_services || return 1
    [ ! -e "$TAILSCALE_UNIT" ] && [ ! -L "$TAILSCALE_UNIT" ] &&
        [ "$(tailscale_service_state is-active "$TAILSCALE_LABEL")" = false ] && [ "$(tailscale_service_state is-enabled "$TAILSCALE_LABEL")" = false ] || return 1
    "$TAILSCALE_BINARY" tailscale-preflight managed-environment "$TAILSCALE_ENV" "$TAILSCALE_STATE" "$TAILSCALE_RELEASE_ROOT" || return 1
    "$TAILSCALE_BINARY" tailscale-preflight ports "$TAILSCALE_PORT" "$(tailscale_env_value HERDR_RELAY_PLUGIN_PORT)" || return 1
    if [ "$(tailscale_state_value route_ownership)" = created ]; then
        tailscale_read_serve || return 1
        [ "$TAILSCALE_ROUTE_STATE" = absent ] || { echo 'A previously owned endpoint reappeared; review it before changing transport or deleting credentials.' >&2; return 1; }
    fi
}

tailscale_local_ready() {
    local pid healthz
    TAILSCALE_HEALTH="$(wait_for_relay_health "$TAILSCALE_PORT" 15 1 "$TAILSCALE_INSTANCE")" || return 1
    pid="$(tailscale_service_pid)" || return 1
    "$TAILSCALE_BINARY" tailscale-preflight listener "$pid" "$TAILSCALE_PORT" "$TAILSCALE_BINARY" || return 1
    healthz="$(curl -fsS --max-time 5 "http://127.0.0.1:$TAILSCALE_PORT/healthz")" || return 1
    printf '%s' "$healthz" | "$TAILSCALE_BINARY" tailscale-preflight gateway-disabled
}

# Used for the pre-consent observation, the native snapshot, and verification
# after restoring the old pointer/unit. Never use legacy evidence for a managed
# unit or accept identity-bearing readiness that failed strict verification.
native_install_readiness_snapshot() {
    local port="$1" instance="$2" version="${3:-}" revision="${4:-}" web_hash="${5:-}"
    local pid executable ready health receipt
    executable="$(tailscale_realpath "$TAILSCALE_RELEASE_ROOT/current/herdr-mobile-relay")" || return 1
    pid="$(tailscale_service_pid)" || return 1
    "$TAILSCALE_BINARY" tailscale-preflight listener "$pid" "$port" "$executable" || return 1
    ready="$(curl -fsS --noproxy '*' --max-time 2 --max-filesize 65536 "http://127.0.0.1:$port/readyz")" || return 1
    if printf '%s' "$ready" | "$TAILSCALE_BINARY" verify-readiness "$instance" "$version" "$revision" "$web_hash" 2>/dev/null; then
        receipt="$ready"
    else
        "$TAILSCALE_BINARY" tailscale-preflight runbook "$TAILSCALE_UNIT" "$TAILSCALE_CONFIG_DIR/start-tailscale-relay.sh" || return 1
        health="$(curl -fsS --noproxy '*' --max-time 2 --max-filesize 65536 "http://127.0.0.1:$port/healthz")" || return 1
        receipt="$(printf '{"ready":%s,"health":%s}' "$ready" "$health" |
            "$TAILSCALE_BINARY" tailscale-preflight runbook-readiness "$instance" "$version" "$revision" "$web_hash")" || return 1
    fi
    [ "$(tailscale_service_pid)" = "$pid" ] &&
        [ "$(tailscale_realpath "$TAILSCALE_RELEASE_ROOT/current/herdr-mobile-relay")" = "$executable" ] || return 1
    "$TAILSCALE_BINARY" tailscale-preflight listener "$pid" "$port" "$executable" || return 1
    printf '%s\n' "$receipt"
}

native_install_verify_previous_readiness() {
    local previous="$1" attempt instance version revision web_hash
    instance="$(json_string_field "$previous" instance)"
    version="$(json_string_field "$previous" release_version)"
    revision="$(json_string_field "$previous" revision)"
    web_hash="$(json_string_field "$previous" bundle_hash)"
    [ -n "$instance" ] && [ -n "$version" ] && [ -n "$revision" ] && [ -n "$web_hash" ] || return 1
    for attempt in {1..15}; do
        if native_install_readiness_snapshot "$native_previous_port" "$instance" "$version" "$revision" "$web_hash" >/dev/null 2>&1; then return 0; fi
        [ "$attempt" -eq 15 ] || sleep 1
    done
    return 1
}

tailscale_existing_ready() {
    local health
    native_install_readiness_snapshot "$TAILSCALE_PORT" "$TAILSCALE_INSTANCE" >/dev/null || return 1
    health="$(curl -fsS --max-time 5 "http://127.0.0.1:$TAILSCALE_PORT/healthz")" || return 1
    printf '%s' "$health" | "$TAILSCALE_BINARY" tailscale-preflight gateway-disabled
}

tailscale_https_ready() {
    local remote attempt
    for attempt in {1..8}; do
        if remote="$(curl -fsS --proto '=https' --max-time 5 "$TAILSCALE_ORIGIN/readyz" 2>/dev/null)" &&
           printf '%s' "$remote" | "$TAILSCALE_BINARY" verify-readiness "$TAILSCALE_INSTANCE" \
                "$(json_string_field "$TAILSCALE_HEALTH" release_version)" "$(json_string_field "$TAILSCALE_HEALTH" revision)" \
                "$(json_string_field "$TAILSCALE_HEALTH" bundle_hash)" 2>/dev/null; then return 0; fi
        [ "$attempt" -eq 8 ] || sleep 1
    done
    echo 'Private HTTPS did not verify the selected relay identity. No invitation was generated.' >&2
    return 1
}

tailscale_pairing_ready() {
    [ "$(tailscale_state_value phase)" = verified ] || { echo 'Complete private setup before generating an invitation.' >&2; return 1; }
    tailscale_check_state_identity || return 1
    [ "$(tailscale_hostname)" = "$TAILSCALE_HOST" ] || { echo 'Tailscale hostname changed; review the saved endpoint and app origin.' >&2; return 1; }
    tailscale_no_other_services || return 1
    tailscale_check_managed_unit && tailscale_check_loaded_unit || return 1
    "$TAILSCALE_BINARY" tailscale-preflight managed-environment "$TAILSCALE_ENV" "$TAILSCALE_STATE" "$TAILSCALE_RELEASE_ROOT" || return 1
    tailscale_read_serve || return 1
    [ "$TAILSCALE_ROUTE_STATE" = matching ] || { echo 'Private endpoint is missing or changed; no invitation generated.' >&2; return 1; }
    tailscale_local_ready && tailscale_https_ready
}

tailscale_app_ready() {
    local metadata
    metadata="$(curl -fsS --proto '=https' --max-time 5 --max-filesize 1048576 "$1/version.json" 2>/dev/null)" &&
        printf '%s' "$metadata" | "$TAILSCALE_BINARY" tailscale-pairing app || {
        echo 'The selected private app host is unavailable or unrecognized. Restore it; no origin failover or invitation was performed.' >&2
        return 1
    }
}

tailscale_change_route() {
    local action="$1"
    local -a command=(tailscale serve)
    if [ "$action" = create ]; then command+=(--bg "--https=$TAILSCALE_HTTPS" "$TAILSCALE_TARGET")
    elif [ "$action" = remove ]; then command+=("--https=$TAILSCALE_HTTPS" off)
    else return 1; fi
    if [ "${TAILSCALE_SUDO:-false}" = true ]; then command=(sudo -- "${command[@]}"); fi
    # Permission and HTTPS consent stay on the attached terminal. No automatic
    # sudo retry: a failed command may already have changed daemon state.
    tailscale_timeout --foreground 120 "${command[@]}"
}

native_install_pre_restore() {
    local phase ownership expected record_recovery
    if [ ! -e "$TAILSCALE_STATE" ] && [ ! -L "$TAILSCALE_STATE" ]; then
        if [ "${native_changed:-false}" = true ]; then echo 'Setup record disappeared; retaining endpoint and recovery evidence.' >&2; return 1; fi
        return 0
    fi
    record_recovery="$(tailscale_state_value recovery_directory)" || return 1
    [ "$record_recovery" = "$native_recovery" ] || return 0
    phase="$(tailscale_state_value phase)" || return 1
    if [ "$phase" != recovery ]; then "$TAILSCALE_BINARY" tailscale-state advance "$TAILSCALE_STATE" "$phase" recovery || return 1; fi
    if [ "${TAILSCALE_KEEP_ROUTE:-false}" = true ]; then
        echo 'Route retained by explicit request; only local resources will be recovered.' >&2
        return 0
    fi
    ownership="$(tailscale_state_value route_ownership)" || return 1
    expected="$(tailscale_state_value unrelated_digest)" || return 1
    tailscale_read_serve || return 1
    [ "$TAILSCALE_DIGEST" = "$expected" ] || { echo 'Serve changed outside this attempt; retaining route and recovery evidence.' >&2; return 1; }
    case "$ownership:$TAILSCALE_ROUTE_STATE" in
        created:matching)
            tailscale_change_route remove || return 1
            tailscale_read_serve || return 1
            [ "$TAILSCALE_ROUTE_STATE" = absent ] && [ "$TAILSCALE_DIGEST" = "$expected" ] ;;
        created:absent|absent:absent|adopted:matching) return 0 ;;
        *) echo 'Endpoint ownership is uncertain. Use --recover --keep-route only after reviewing the retained endpoint.' >&2; return 1 ;;
    esac
}

# Do not overwrite an administrator's newer files or stop their replacement
# service. The operation lock serializes our tools, not arbitrary external edits.
native_install_restore_allowed() {
    local path old new kind
    native_skip_stop=false
    if [ -e "$TAILSCALE_UNIT" ] || [ -L "$TAILSCALE_UNIT" ]; then tailscale_check_loaded_unit || return 1
    elif [ "$(tailscale_service_state is-active "$TAILSCALE_LABEL")" = false ]; then native_skip_stop=true
    else echo 'An active service lost its definition; manual recovery review required.' >&2; return 1; fi
    for kind in unit environment; do
        if [ "$kind" = unit ]; then path="$TAILSCALE_UNIT"; old="$native_recovery/0"; new="$native_recovery/new.service"
        else path="$TAILSCALE_ENV"; old="$native_recovery/2"; new="$native_recovery/new.env"; fi
        if [ -e "$path" ] || [ -L "$path" ]; then
            if [ "$kind" = unit ]; then
                tailscale_check_managed_unit "$path" || "$TAILSCALE_BINARY" tailscale-preflight runbook "$path" "$TAILSCALE_CONFIG_DIR/start-tailscale-relay.sh" || return 1
            else
                "$TAILSCALE_BINARY" tailscale-preflight environment "$path" || return 1
            fi
            if ! { [ -f "$old" ] && cmp -s "$path" "$old"; } && ! { [ -f "$new" ] && cmp -s "$path" "$new"; }; then
                echo 'A local definition changed outside this attempt; retaining it and private recovery evidence.' >&2
                return 1
            fi
        elif [ -e "$old" ]; then
            echo 'A preexisting local definition disappeared; manual recovery review required.' >&2
            return 1
        fi
    done
    tailscale_check_release_recovery
}

tailscale_check_release_recovery() {
    local record current
    TAILSCALE_PREVIOUS_RELEASE='' TAILSCALE_CANDIDATE_RELEASE=''
    [ -e "$native_recovery/previous-release" ] || [ -L "$native_recovery/previous-release" ] ||
        [ -e "$native_recovery/candidate-release" ] || [ -L "$native_recovery/candidate-release" ] || return 0
    record="$("$TAILSCALE_BINARY" tailscale-preflight release-record "$native_recovery" "$TAILSCALE_RELEASE_ROOT")" || return 1
    IFS=$'\t' read -r TAILSCALE_PREVIOUS_RELEASE TAILSCALE_CANDIDATE_RELEASE <<< "$record"
    [ -L "$TAILSCALE_RELEASE_ROOT/current" ] || return 1
    current="$(tailscale_realpath "$TAILSCALE_RELEASE_ROOT/current")" || return 1
    [ "$current" = "$TAILSCALE_PREVIOUS_RELEASE" ] || [ "$current" = "$TAILSCALE_CANDIDATE_RELEASE" ] || { echo 'Release pointer changed externally; refusing bootstrap rollback.' >&2; return 1; }
    "$TAILSCALE_PREVIOUS_RELEASE/herdr-mobile-relay" verify-release "$TAILSCALE_PREVIOUS_RELEASE" >/dev/null
}

native_install_restore_release() {
    tailscale_check_release_recovery || return 1
    [ -n "${TAILSCALE_PREVIOUS_RELEASE:-}" ] || return 0
    "$TAILSCALE_BINARY" activate-release "$TAILSCALE_RELEASE_ROOT" "$TAILSCALE_PREVIOUS_RELEASE"
}

native_install_post_restore() {
    local record_recovery
    [ -e "$TAILSCALE_STATE" ] || [ -L "$TAILSCALE_STATE" ] || return 0
    record_recovery="$(tailscale_state_value recovery_directory)" || return 1
    [ "$record_recovery" = "$native_recovery" ] || return 0
    if [ "$1" = false ]; then "$TAILSCALE_BINARY" tailscale-state advance "$TAILSCALE_STATE" recovery rolled-back; fi
}

tailscale_recover() {
    local phase flags source instance
    phase="$(tailscale_state_value phase)" || return 1
    case "$phase" in prepared|local-ready|route-pending|route-ready|recovery) ;; *) echo 'No incomplete installation is available for recovery.' >&2; return 1 ;; esac
    native_recovery="$(tailscale_state_value recovery_directory)" || return 1
    [ "$(dirname "$native_recovery")" = "$HOME/.local/state/herdr-mobile-relay/recovery" ] || return 1
    case "$(basename "$native_recovery")" in herdr-native-recovery.*) ;; *) return 1 ;; esac
    [ -d "$native_recovery" ] && [ ! -L "$native_recovery" ] || return 1
    flags="$("$TAILSCALE_BINARY" tailscale-preflight native-record "$native_recovery/state" "$TAILSCALE_UNIT" "$TAILSCALE_ENV")" || return 1
    for source in "$native_recovery/2" "$native_recovery/new.env" "$TAILSCALE_ENV"; do
        [ ! -L "$source" ] || return 1
        if [ -e "$source" ]; then
            instance="$(tailscale_env_value HERDR_RELAY_INSTANCE_ID "$source")" || return 1
            [ "$instance" = "$TAILSCALE_INSTANCE" ] || { echo 'Recovery environment identity changed; refusing to overwrite it.' >&2; return 1; }
        fi
    done
    if [ -e "$native_recovery/0" ] || [ -L "$native_recovery/0" ]; then
        tailscale_check_managed_unit "$native_recovery/0" || "$TAILSCALE_BINARY" tailscale-preflight runbook "$native_recovery/0" "$TAILSCALE_CONFIG_DIR/start-tailscale-relay.sh" || return 1
    fi
    if [ -e "$TAILSCALE_UNIT" ] || [ -L "$TAILSCALE_UNIT" ]; then
        tailscale_check_managed_unit || "$TAILSCALE_BINARY" tailscale-preflight runbook "$TAILSCALE_UNIT" "$TAILSCALE_CONFIG_DIR/start-tailscale-relay.sh" || return 1
    elif [ "$(tailscale_service_state is-active "$TAILSCALE_LABEL")" = true ]; then
        echo 'An active service has no recognized unit file; refusing automatic recovery.' >&2
        return 1
    fi
    echo 'Recover only this attempt: restore previous unit/environment/activation; preserve device-auth and unrelated routes.'
    if [ "$TAILSCALE_KEEP_ROUTE" = true ]; then echo 'The Serve endpoint will be retained even if this attempt created it.'; fi
    tailscale_confirm 'Approve this recovery?' || return 1
    IFS=$'\t' read -r native_active native_enabled <<< "$flags"
    native_manager="${TAILSCALE_MANAGER:-systemd}" native_definition="$TAILSCALE_UNIT" native_environment="$TAILSCALE_ENV" native_label="$TAILSCALE_LABEL"
    native_legacy_definition='' native_legacy_label='' native_legacy_active=false native_legacy_enabled=false
    native_snapshot_complete=true native_changed=true native_committed=false native_stage='' native_keep_recovery=true
    native_previous_port="$TAILSCALE_PORT" native_previous_ready=false native_recovery_command=true
    if [ -e "$native_recovery/previous-ready.json" ]; then
        private_owned_file "$native_recovery/previous-ready.json" || return 1
        "$TAILSCALE_BINARY" verify-readiness "$TAILSCALE_INSTANCE" '' '' '' < "$native_recovery/previous-ready.json" || return 1
        native_previous_ready=true
    fi
    native_install_exit
}

# Private hooks keep the generic legacy transaction unchanged while preserving
# the platform's active/enabled intent through a failed private setup.
native_install_snapshot_activation() {
    native_active="$(tailscale_service_state is-active "$native_label")" || return 1
    native_enabled="$(tailscale_service_state is-enabled "$native_label")"
}
native_install_stop_for_restore() {
    [ "${native_skip_stop:-false}" != true ] || return 0
    tailscale_service stop "$native_label" || return 1
    if [ "$native_enabled" = false ] && [ -f "$native_definition" ]; then tailscale_service disable "$native_label"; fi
}
native_install_restore_private_activation() {
    tailscale_service daemon-reload || return 1
    if [ -f "$native_definition" ]; then
        if [ "$native_enabled" = true ]; then tailscale_service enable "$native_label" || return 1
        else tailscale_service disable "$native_label" || return 1; fi
    fi
    if [ "$native_active" = true ]; then
        # launchd refuses bootstrap of a disabled job. Restore its running state
        # first, then restore the disabled-at-next-login override on this job.
        if [ "${TAILSCALE_MANAGER:-systemd}" = launchd ] && [ "$native_enabled" = false ]; then
            tailscale_service enable "$native_label" || return 1
            local restarted=true
            tailscale_service restart "$native_label" || restarted=false
            tailscale_service disable "$native_label" || return 1
            [ "$restarted" = true ]
        else tailscale_service restart "$native_label"; fi
    fi
}
