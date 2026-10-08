#!/usr/bin/env bash
set -euo pipefail
TAILSCALE_FIXTURE_LIBRARY=1 source "$(dirname "$0")/test_tailscale_setup.sh"

for kind in environment device-data legacy-environment legacy-service directory-symlink; do
    new_case "consent-$kind"
    mkfifo "$CASE/input"
    exec 7<>"$CASE/input"
    timeout 30 script -qefc "bash '$REPO_DIR/relay/tailscale-setup.sh' --no-pair" /dev/null <"$CASE/input" >"$CASE/output" 2>&1 &
    wizard=$!
    approved=false
    for ((attempt=0; attempt<500; attempt++)); do
        if grep -q 'Approve these changes?' "$CASE/output"; then approved=true; break; fi
        /bin/sleep .02
    done
    if [[ "$approved" != true ]]; then
        kill "$wizard" 2>/dev/null || true
        wait "$wizard" || true
        echo 'wizard did not reach approval' >&2; exit 1
    fi
    mkdir -p "${ENV_FILE%/*}" "${UNIT%/*}"
    case "$kind" in
        environment) appeared="$ENV_FILE" ;;
        device-data) mkdir -p "${ENV_FILE%/*}/device-auth"; appeared="${ENV_FILE%/*}/device-auth/sentinel" ;;
        legacy-environment) appeared="${ENV_FILE%/*}/.env" ;;
        legacy-service) appeared="${UNIT%/*}/herdr-mobile-relay.service" ;;
        directory-symlink)
            rmdir "${ENV_FILE%/*}"
            mkdir "$CASE/foreign"; chmod 755 "$CASE/foreign"
            ln -s "$CASE/foreign" "${ENV_FILE%/*}"
            appeared="$CASE/foreign/sentinel" ;;
    esac
    printf 'identity created by another operation\n' > "$appeared"
    cp "$appeared" "$CASE/expected"
    printf 'y\n' >&7
    if wait "$wizard"; then echo "fresh setup overwrote consent-time $kind" >&2; exit 1; fi
    exec 7>&-
    cmp "$appeared" "$CASE/expected"
    [[ ! -e "$STATE" && ! -e "$UNIT" ]]
    if grep -Eq 'systemctl --user (enable|restart|stop|daemon-reload)|tailscale serve --bg' "$CASE/calls"; then
        echo 'consent drift reached resource mutation' >&2; exit 1
    fi
    if [[ "$kind" == directory-symlink ]]; then
        [[ "$(stat -c %a "$CASE/foreign")" == 755 ]]
    fi
done
for orphan in .env device-auth; do
    new_case "orphan-$orphan"
    mkdir -p "${ENV_FILE%/*}"
    ln -s "$CASE/missing-identity" "${ENV_FILE%/*}/$orphan"
    if run_wizard y; then echo 'fresh setup accepted dangling orphan identity' >&2; exit 1; fi
    [[ ! -e "$ENV_FILE" && ! -e "$STATE" && -L "${ENV_FILE%/*}/$orphan" ]]
done
echo 'fresh setup preserves identity and paths changed during approval'
