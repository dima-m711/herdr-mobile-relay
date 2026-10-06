#!/usr/bin/env bash
# macOS backend for the managed private service. Only the signed-in user's GUI
# domain and the exact owned job are mutated; no daemon, sudo or global reset.
set +x

tailscale_render_launchagent() {
    local release="${1:-$TAILSCALE_RELEASE_ROOT/current}"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict>'
    printf '<key>Label</key><string>%s</string>\n' "$TAILSCALE_LABEL"
    printf '<key>ProgramArguments</key><array><string>/bin/bash</string><string>%s</string></array>\n' "$(plist_text "$release/relay/tailscale-service.sh")"
    printf '<key>WorkingDirectory</key><string>%s</string>\n' "$(plist_text "$release")"
    printf '<key>EnvironmentVariables</key><dict><key>HERDR_RELAY_ENV</key><string>%s</string><key>PATH</key><string>%s</string></dict>\n' "$(plist_text "$TAILSCALE_ENV")" "$(plist_text "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")"
    printf '%s\n' '<key>RunAtLoad</key><true/>' '<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>' '<key>ThrottleInterval</key><integer>5</integer>' '<key>Umask</key><integer>63</integer>' '</dict></plist>'
}

tailscale_launchctl() { tailscale_timeout 10 /bin/launchctl "$@"; }

# Distinguish an absent job from an unavailable GUI domain or failed query.
# A failed print is only absence when a complete job-list query confirms it.
tailscale_launchd_snapshot() {
    tailscale_launchctl print "gui/$UID" >/dev/null 2>&1 || return 1
    if TAILSCALE_JOB="$(tailscale_launchctl print "gui/$UID/$1" 2>/dev/null)"; then
        TAILSCALE_LOADED=true
    else
        local loaded
        loaded="$(tailscale_launchctl list | "$(relay_binary)" tailscale-platform launchd-loaded "$1")" || return 1
        [ "$loaded" = false ] || return 1
        TAILSCALE_JOB='' TAILSCALE_LOADED=false
    fi
}

tailscale_darwin_state() {
    local action="$1" label="$2" disabled
    tailscale_launchd_snapshot "$label" || return 1
    case "$action" in
        is-active) printf '%s' "$TAILSCALE_LOADED" ;;
        is-enabled)
            if [ ! -e "$TAILSCALE_UNIT_DIR/$label.plist" ]; then printf false; return; fi
            disabled="$(tailscale_launchctl print-disabled "gui/$UID" | "$(relay_binary)" tailscale-platform launchd-disabled "$label")" || return 1
            if [ "$disabled" = true ]; then printf false; else printf true; fi ;;
        *) return 1 ;;
    esac
}

tailscale_darwin_check_loaded() {
    tailscale_launchd_snapshot "$TAILSCALE_LABEL" || return 1
    [ "$TAILSCALE_LOADED" = true ] || return 0
    printf '%s' "$TAILSCALE_JOB" | "$(relay_binary)" tailscale-platform launchd-verify "$TAILSCALE_UNIT" "$TAILSCALE_RELEASE_ROOT/current" "$TAILSCALE_ENV" "$TAILSCALE_LABEL"
}

tailscale_darwin_pid() {
    tailscale_darwin_check_loaded || return 1
    [ "$TAILSCALE_LOADED" = true ] || return 1
    printf '%s' "$TAILSCALE_JOB" | "$(relay_binary)" tailscale-platform launchd-pid
}

tailscale_darwin_stop() {
    local attempt
    tailscale_darwin_check_loaded || return 1
    [ "$TAILSCALE_LOADED" = true ] || return 0
    tailscale_launchctl bootout "gui/$UID/$TAILSCALE_LABEL" || return 1
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        tailscale_darwin_check_loaded || return 1
        [ "$TAILSCALE_LOADED" = true ] || return 0
        sleep 1
    done
    echo 'Timed out waiting for the private LaunchAgent to unload.' >&2
    return 1
}

tailscale_darwin_service() {
    local action="$1" attempt
    case "$action" in
        reload) return 0 ;;
        enable|disable) tailscale_launchctl "$action" "gui/$UID/$TAILSCALE_LABEL" ;;
        stop) tailscale_darwin_stop ;;
        start|restart)
            [ "$(tailscale_darwin_state is-enabled "$TAILSCALE_LABEL")" = true ] || {
                echo 'The private LaunchAgent is disabled; explicitly enable the owned job before starting it.' >&2; return 1;
            }
            tailscale_darwin_check_loaded || return 1
            if [ "$action" = restart ] && [ "$TAILSCALE_LOADED" = true ]; then
                tailscale_darwin_stop || return 1
            fi
            if [ "$TAILSCALE_LOADED" = false ]; then
                for attempt in 1 2 3 4 5; do
                    # As in the legacy installer, launchd may still be finishing
                    # bootout. A failed bootstrap never authorizes killing a job.
                    tailscale_launchctl bootstrap "gui/$UID" "$TAILSCALE_UNIT" || true
                    tailscale_darwin_check_loaded || return 1
                    [ "$TAILSCALE_LOADED" = false ] || break
                    [ "$attempt" -eq 5 ] || sleep 1
                done
                [ "$TAILSCALE_LOADED" = true ] || { echo 'Private LaunchAgent bootstrap failed.' >&2; return 1; }
            fi
            tailscale_launchctl kickstart "gui/$UID/$TAILSCALE_LABEL" ;;
        *) return 1 ;;
    esac
}
