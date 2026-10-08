#!/bin/sh
# Install one exact, complete Herdr Mobile Relay release. No toolchain needed.
set +x
set -eu

unset herdr_download_token
herdr_download_token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
unset GH_TOKEN GITHUB_TOKEN

REPO=${HERDR_RELEASE_REPOSITORY:-dima-m711/herdr-mobile-relay}
BINARY=herdr-mobile-relay

info() { printf '==> %s\n' "$1" >&2; }
fatal() { printf 'error: %s\n' "$1" >&2; exit 1; }

detect_os() {
    case "$(uname -s)" in
        Linux) printf '%s\n' linux ;;
        Darwin) printf '%s\n' darwin ;;
        *) fatal "unsupported OS: $(uname -s)" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s\n' amd64 ;;
        aarch64|arm64) printf '%s\n' arm64 ;;
        *) fatal "unsupported architecture: $(uname -m)" ;;
    esac
}

run_with_timeout() {
    herdr_timeout_seconds=$1
    shift
    "$@" &
    herdr_command_pid=$!
    exec 3<&-
    herdr_elapsed=0
    while kill -0 "$herdr_command_pid" 2>/dev/null; do
        if [ "$herdr_elapsed" -ge "$herdr_timeout_seconds" ]; then
            kill -9 "$herdr_command_pid" 2>/dev/null || true
            wait "$herdr_command_pid" 2>/dev/null || true
            herdr_command_pid=
            return 124
        fi
        sleep 1
        herdr_elapsed=$((herdr_elapsed + 1))
    done
    if wait "$herdr_command_pid"; then
        herdr_status=0
    else
        herdr_status=$?
    fi
    herdr_command_pid=
    return "$herdr_status"
}

terminate_active_command() {
    herdr_signal=$1
    if [ -z "${herdr_command_pid:-}" ]; then
        return 0
    fi
    kill "$herdr_signal" "$herdr_command_pid" 2>/dev/null || true
    herdr_signal_elapsed=0
    while kill -0 "$herdr_command_pid" 2>/dev/null; do
        if [ "$herdr_signal_elapsed" -ge 2 ]; then
            kill -KILL "$herdr_command_pid" 2>/dev/null || true
            break
        fi
        sleep 1
        herdr_signal_elapsed=$((herdr_signal_elapsed + 1))
    done
    wait "$herdr_command_pid" 2>/dev/null || true
    herdr_command_pid=
}

on_install_exit() {
    unset herdr_download_token
    terminate_active_command -TERM
    if [ -n "${work_dir:-}" ]; then
        rm -rf "$work_dir"
    fi
}

on_install_signal() {
    herdr_signal=$1
    herdr_exit_status=$2
    terminate_active_command "$herdr_signal"
    exit "$herdr_exit_status"
}

fetch() {
    download_release "$1" "$2" application/octet-stream
}

fetch_json() {
    download_release "$1" - application/vnd.github+json
}

download_release() {
    set +x
    if [ -n "$herdr_download_token" ]; then
        case "$herdr_download_token" in
            *[!a-zA-Z0-9_.-]*) fatal "invalid release download token" ;;
        esac
        case "$1" in
            https://api.github.com/*) ;;
            *) fatal "authenticated downloads require the GitHub API origin" ;;
        esac
        command -v curl >/dev/null 2>&1 || fatal "curl is required for authenticated downloads"
        run_with_timeout 120 curl --disable --fail --show-error --silent --location \
            --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 \
            --config /dev/fd/3 --output "$2" -H "Accept: $3" "$1" 3<<EOF
header = "Authorization: token $herdr_download_token"
EOF
        return $?
    fi
    if command -v curl >/dev/null 2>&1; then
        run_with_timeout 120 curl --disable --fail --show-error --silent --location \
            --connect-timeout 10 --max-time 120 --output "$2" -H "Accept: $3" "$1"
    elif command -v wget >/dev/null 2>&1; then
        run_with_timeout 120 wget --quiet --timeout=120 --tries=1 --output-document="$2" \
            --header="Accept: $3" "$1"
    else
        fatal "curl or wget is required"
    fi
}

resolve_asset_url() {
    release_json=$1
    asset_name=$2
    # GitHub places the asset API URL before the asset name and nested uploader
    # URLs after it. Split at every URL key, then select the record whose
    # following fields contain the exact asset name.
    printf '%s' "$release_json" |
        tr -d '\n\r\t ' |
        sed 's/"url":"/\
"url":"/g' |
        awk -v name="\"name\":\"$asset_name\"" '
            index($0, name) == 0 { next }
            {
                line = $0
                sub(/^"url":"/, "", line)
                sub(/".*$/, "", line)
                print line
                exit
            }
        '
}

resolve_tag_revision() {
    commit_json=$1
    printf '%s' "$commit_json" |
        tr -d '\n\r\t ' |
        sed 's/"sha":"/\
"sha":"/' |
        sed -n 's/^"sha":"\([0-9a-fA-F][0-9a-fA-F]*\)".*/\1/p' |
        head -1
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

validate_archive_paths() {
    tar -tzf "$1" | awk '
        {
            name = $0
            sub(/^\.\//, "", name)
            if (name ~ /^\// || name ~ /(^|\/)\.\.(\/|$)/ || name ~ /\\/) {
                bad = 1
            }
        }
        END { exit bad ? 1 : 0 }
    ' || return 1
    tar -tvzf "$1" | awk '
        {
            kind = substr($1, 1, 1)
            if (kind != "-" && kind != "d") {
                bad = 1
            }
        }
        END { exit bad ? 1 : 0 }
    ' || return 1
}

legacy_root_entry_allowed() {
    root_kind=$1
    entry_name=$2
    entry_path=$3
    case "$root_kind:$entry_name" in
        config:relay.env|config:.env|config:phone-app-origin|config:phone-app-origin-configured|config:stable-setup.json|\
        config:update-state.json|config:app-deploy-state.json|config:support-state.json|config:github-token|\
        config:update.lock|config:app-deploy.lock)
            [ -f "$entry_path" ] && [ ! -L "$entry_path" ]
            ;;
        config:update-job-*.json|config:app-deploy-job-*.json)
            [ -f "$entry_path" ] && [ ! -L "$entry_path" ]
            ;;
        config:device-auth|config:push|config:cloudflared)
            [ -d "$entry_path" ] && [ ! -L "$entry_path" ]
            ;;
        cache:activity.jsonl|cache:activity.tombstones|cache:post-install.sh|cache:post-install.log|\
        cache:approval-verification*|cache:notification-approval-fix-test-*)
            [ -f "$entry_path" ] && [ ! -L "$entry_path" ]
            ;;
        cache:claude-history|cache:uploads|cache:push)
            [ -d "$entry_path" ] && [ ! -L "$entry_path" ]
            ;;
        *)
            return 1
            ;;
    esac
}

validate_legacy_root() {
    legacy_root=$1
    root_kind=$2
    [ -d "$legacy_root" ] && [ ! -L "$legacy_root" ] || return 1
    [ -z "$(find "$legacy_root" -type l -print -quit)" ] || return 1
    found=false
    cache_state=false
    cache_waiter_script=false
    cache_waiter_log=false
    for legacy_entry in "$legacy_root"/* "$legacy_root"/.[!.]* "$legacy_root"/..?*; do
        [ -e "$legacy_entry" ] || continue
        legacy_name=${legacy_entry##*/}
        [ "$legacy_name" != ".herdr-mobile-relay-installation" ] || continue
        if [ "$root_kind:$legacy_name" = config:.setup.lock ]; then
            private_owned_file "$legacy_entry" || return 1
            continue
        fi
        legacy_root_entry_allowed "$root_kind" "$legacy_name" "$legacy_entry" || return 1
        found=true
        case "$legacy_name" in
            activity.jsonl|claude-history|uploads) cache_state=true ;;
            post-install.sh) cache_waiter_script=true ;;
            post-install.log) cache_waiter_log=true ;;
        esac
    done
    [ "$found" = true ] || return 1
    if [ "$root_kind" = config ]; then
        legacy_env=
        [ ! -f "$legacy_root/relay.env" ] || legacy_env="$legacy_root/relay.env"
        [ -n "$legacy_env" ] || [ ! -f "$legacy_root/.env" ] || legacy_env="$legacy_root/.env"
        [ -n "$legacy_env" ] || return 1
        grep -q '^HERDR_RELAY_TOKEN=' "$legacy_env" || return 1
    elif [ "$root_kind" = cache ]; then
        [ "$cache_state" = true ] ||
            { [ "$cache_waiter_script" = true ] && [ "$cache_waiter_log" = true ]; } ||
            return 1
    fi
}

private_owned_file() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    file_identity=$(stat -c '%u:%a:%h' "$1" 2>/dev/null) ||
        file_identity=$(stat -f '%u:%Lp:%l' "$1" 2>/dev/null) || return 1
    [ "$file_identity" = "$(id -u):600:1" ]
}

write_install_sentinel() {
    sentinel_root=$1
    root_kind=${2:-new}
    sentinel="$sentinel_root/.herdr-mobile-relay-installation"
    [ ! -L "$sentinel" ] || fatal "installation ownership sentinel must not be a symbolic link"
    if [ -f "$sentinel" ]; then
        private_owned_file "$sentinel" || fatal "installation ownership sentinel must be private, owned by this user, and have one link"
        canonical_root=$(CDPATH='' cd "$sentinel_root" && pwd -P)
        grep -Fx 'product=herdr-mobile-relay' "$sentinel" >/dev/null &&
            grep -Fx "root=$canonical_root" "$sentinel" >/dev/null ||
            fatal "installation root has a mismatched ownership sentinel: $sentinel_root"
        return
    fi
    if [ -e "$sentinel_root" ]; then
        [ -d "$sentinel_root" ] ||
            fatal "installation root is not a directory: $sentinel_root"
        if [ "$root_kind" = config ] && { [ -e "$sentinel_root/.setup.lock" ] || [ -L "$sentinel_root/.setup.lock" ]; }; then
            private_owned_file "$sentinel_root/.setup.lock" || fatal "unsafe configuration lifecycle lock"
            root_entry=$(find "$sentinel_root" -mindepth 1 -maxdepth 1 ! -name .setup.lock -print -quit)
        else
            root_entry=$(find "$sentinel_root" -mindepth 1 -maxdepth 1 -print -quit)
        fi
        if [ -n "$root_entry" ]; then
            case "$root_kind" in
                config|cache)
                    validate_legacy_root "$sentinel_root" "$root_kind" ||
                        fatal "refusing to claim nonempty directory without a validated Python 0.8.6 layout: $sentinel_root"
                    ;;
                *)
                    fatal "refusing to claim nonempty directory without an ownership sentinel: $sentinel_root"
                    ;;
            esac
        fi
    else
        mkdir -p "$sentinel_root"
    fi
    chmod 700 "$sentinel_root"
    canonical_root=$(CDPATH='' cd "$sentinel_root" && pwd -P)
    sentinel_temp="$sentinel_root/.herdr-mobile-relay-installation.$$"
    {
        printf 'product=herdr-mobile-relay\n'
        printf 'root=%s\n' "$canonical_root"
    } > "$sentinel_temp"
    chmod 600 "$sentinel_temp"
    mv -f "$sentinel_temp" "$sentinel_root/.herdr-mobile-relay-installation"
}

prepare_install_roots() {
    release_root=$1
    config_root=$2
    cache_root=$3
    legacy_cache="$HOME/.cache/herdr-mobile-relay"

    write_install_sentinel "$release_root" new
    write_install_sentinel "$config_root" config

    if [ "$cache_root" != "$legacy_cache" ] &&
       [ -d "$legacy_cache" ] &&
       [ ! -e "$legacy_cache/.herdr-mobile-relay-installation" ]; then
        validate_legacy_root "$legacy_cache" cache ||
            fatal "legacy Python cache has unexpected contents: $legacy_cache"
        if [ -e "$cache_root" ]; then
            [ -d "$cache_root" ] || fatal "cache destination is not a directory: $cache_root"
            if [ -n "$(find "$cache_root" -mindepth 1 -maxdepth 1 -print -quit)" ] &&
               [ ! -f "$cache_root/.herdr-mobile-relay-installation" ]; then
                validate_legacy_root "$cache_root" cache ||
                    fatal "cannot migrate the Python cache into unowned destination: $cache_root"
            fi
        else
            mkdir -p "$cache_root"
        fi
        for legacy_entry in "$legacy_cache"/* "$legacy_cache"/.[!.]* "$legacy_cache"/..?*; do
            [ -e "$legacy_entry" ] || continue
            legacy_name=${legacy_entry##*/}
            [ ! -e "$cache_root/$legacy_name" ] ||
                fatal "legacy Python cache entry already exists at destination: $legacy_name"
            mv "$legacy_entry" "$cache_root/$legacy_name" ||
                fatal "could not migrate legacy Python cache entry: $legacy_name"
        done
        rmdir "$legacy_cache" ||
            fatal "could not remove migrated legacy Python cache root"
        info "Migrated Python cache from $legacy_cache to $cache_root"
    fi
    write_install_sentinel "$cache_root" cache
}

# Serialize release-directory publication, including staging-only callers.
# Private lifecycle orchestration takes its config lease before this lease.
acquire_install_lock() {
    [ "$(uname -s)" = Linux ] || return 0
    command -v flock >/dev/null 2>&1 || fatal "flock is required on Linux"
    install_lock="$1/.install.lock"
    if [ ! -e "$install_lock" ] && [ ! -L "$install_lock" ]; then
        (umask 077; set -C; : > "$install_lock") || fatal "could not create installer lock"
    fi
    private_owned_file "$install_lock" || fatal "unsafe installer lock"
    exec 9>>"$install_lock"
    private_owned_file "$install_lock" || fatal "installer lock changed"
    [ "$(stat -Lc '%d:%i' /proc/$$/fd/9)" = "$(stat -c '%d:%i' "$install_lock")" ] || fatal "installer lock identity changed"
    flock -n 9 || fatal "another release installation is running"
}

# Normal activation must exclude first-time private setup even when this
# standalone install uses a historical/custom legacy config root. Stage-only
# publication never takes this lease or changes configuration roots.
acquire_private_setup_lease() {
    [ "$(uname -s)" = Linux ] || return 0
    command -v flock >/dev/null 2>&1 || fatal "flock is required on Linux"
    setup_directory="$HOME/.config/herdr/plugins/config/herdr-mobile-relay.events"
    ancestor="$setup_directory"
    while [ "$ancestor" != / ]; do
        [ ! -L "$ancestor" ] && { [ ! -e "$ancestor" ] || [ -d "$ancestor" ]; } || fatal "unsafe private setup directory"
        ancestor=$(dirname "$ancestor")
    done
    (umask 077; mkdir -p "$setup_directory")
    [ "$(stat -c %u "$setup_directory")" = "$(id -u)" ] &&
        [ "$((0$(stat -c %a "$setup_directory") & 0022))" -eq 0 ] || fatal "unsafe private setup directory permissions"
    setup_lock="$setup_directory/.setup.lock"
    if [ ! -e "$setup_lock" ] && [ ! -L "$setup_lock" ]; then
        (umask 077; set -C; : > "$setup_lock") || fatal "could not create setup lock"
    fi
    private_owned_file "$setup_lock" || fatal "unsafe private setup lock"
    setup_identity=$(stat -c '%d:%i' "$setup_lock")
    setup_inherited=${HERDR_RELAY_SETUP_LOCK_FD:-}
    case "$setup_inherited" in *[!0-9]*) fatal "invalid inherited setup lease" ;; esac
    if [ -n "$setup_inherited" ] && [ "$(stat -Lc '%d:%i' "/proc/$$/fd/$setup_inherited" 2>/dev/null)" = "$setup_identity" ]; then
        flock -n "$setup_inherited" || fatal "another private lifecycle change is running"
        return
    fi
    exec 8>>"$setup_lock"
    private_owned_file "$setup_lock" &&
        [ "$(stat -Lc '%d:%i' /proc/$$/fd/8)" = "$setup_identity" ] &&
        [ "$(stat -c '%d:%i' "$setup_lock")" = "$setup_identity" ] || fatal "private setup lock changed"
    flock -n 8 || fatal "another private lifecycle change is running"
}

refuse_private_activation() {
    if [ -e "$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service" ] ||
       [ -L "$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service" ]; then
        fatal "private installations require the Tailscale-aware plugin updater; standalone activation refused"
    fi
    for private_config in "$config_root" "$HOME/.config/herdr/plugins/config/herdr-mobile-relay.events"; do
        if [ -f "$private_config/relay.env" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?HERDR_CONNECTION_MODE=.*tailscale' "$private_config/relay.env"; then
            fatal "private installations require the Tailscale-aware plugin updater; standalone activation refused"
        fi
    done
}

main() {
    command -v tar >/dev/null 2>&1 || fatal "tar is required"
    command -v awk >/dev/null 2>&1 || fatal "awk is required"
    command -v find >/dev/null 2>&1 || fatal "find is required"

    stage_only=${HERDR_RELEASE_STAGE_ONLY:-0}
    required_mode=${HERDR_RELEASE_REQUIRED_MODE:-}
    case "$stage_only" in 0|1) ;; *) fatal "invalid staging-only selector" ;; esac
    case "$required_mode" in ''|tailscale) ;; *) fatal "unsupported required connection mode" ;; esac
    version=${VERSION:-${1:-}}
    [ -n "$version" ] || fatal "an exact VERSION is required; unpinned latest installs are refused"
    version=${version#v}
    case "$version" in
        *[!0-9.]*|.*|*..*|*.) fatal "VERSION must use MAJOR.MINOR.PATCH" ;;
    esac
    [ "$(printf '%s' "$version" | awk -F. '{print NF}')" -eq 3 ] ||
        fatal "VERSION must use MAJOR.MINOR.PATCH"

    os=$(detect_os)
    arch=$(detect_arch)
    target="$os/$arch"
    archive="${BINARY}_${version}_${os}_${arch}.tar.gz"
    tag="v$version"
    release_root=${INSTALL_ROOT:-"${XDG_DATA_HOME:-$HOME/.local/share}/herdr-mobile-relay"}
    shim_dir=${BIN_DIR:-"$HOME/.local/bin"}
    if [ -n "${HERDR_RELAY_ENV:-}" ]; then
        config_root=$(dirname "$HERDR_RELAY_ENV")
    else
        config_root=${HERDR_PLUGIN_CONFIG_DIR:-"${XDG_CONFIG_HOME:-$HOME/.config}/herdr-mobile-relay"}
    fi
    cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/herdr-mobile-relay"
    if [ "$stage_only" = 0 ]; then
        refuse_private_activation
    fi

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/herdr-install.XXXXXX")
    trap 'on_install_exit' EXIT
    trap 'on_install_signal -INT 130' INT
    trap 'on_install_signal -TERM 143' TERM
    archive_path="$work_dir/$archive"
    checksums_path="$work_dir/checksums.txt"
    stage="$work_dir/release"
    commit_json_path="$work_dir/commit.json"

    info "Resolving ${BINARY} ${version} (${target}) from ${REPO}"
    fetch_json "https://api.github.com/repos/${REPO}/commits/${tag}" > "$commit_json_path" ||
        fatal "could not resolve release tag from GitHub API (private repositories require GH_TOKEN; SSH access authenticates Git only)"
    commit_json=$(awk '{ printf "%s", $0 }' "$commit_json_path")
    tag_revision=$(resolve_tag_revision "$commit_json")
    case "$tag_revision" in
        ????????????????????????????????????????) ;;
        *) fatal "release tag did not resolve to an exact commit" ;;
    esac
    info "Downloading ${archive} from ${REPO}"
    if [ -n "$herdr_download_token" ]; then
        api_url="https://api.github.com/repos/${REPO}/releases/tags/${tag}"
        release_json_path="$work_dir/release.json"
        fetch_json "$api_url" > "$release_json_path" ||
            fatal "could not fetch release metadata from GitHub API"
        release_json=$(awk '{ printf "%s", $0 }' "$release_json_path")
        archive_url=$(resolve_asset_url "$release_json" "$archive")
        checksum_url=$(resolve_asset_url "$release_json" "checksums.txt")
        [ -n "$archive_url" ] || fatal "release has no asset named $archive"
        [ -n "$checksum_url" ] || fatal "release has no asset named checksums.txt"
        fetch "$checksum_url" "$checksums_path" ||
            fatal "required checksums.txt download failed"
        fetch "$archive_url" "$archive_path" ||
            fatal "release archive download failed"
    else
        base_url=${HERDR_RELEASE_BASE_URL:-"https://github.com/${REPO}/releases/download/${tag}"}
        fetch "$base_url/checksums.txt" "$checksums_path" ||
            fatal "required checksums.txt download failed"
        fetch "$base_url/$archive" "$archive_path" ||
            fatal "release archive download failed"
    fi

    matches=$(awk -v name="$archive" '
        NF == 2 {
            file = $2
            sub(/^\*/, "", file)
            if (file == name) print tolower($1)
        }
    ' "$checksums_path")
    count=$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')
    [ "$count" -eq 1 ] || fatal "checksums.txt must contain one exact entry for $archive"
    expected=$(printf '%s\n' "$matches" | awk 'NF { print; exit }')
    actual=$(sha256_file "$archive_path")
    [ "$expected" = "$actual" ] || fatal "checksum mismatch for $archive"

    validate_archive_paths "$archive_path" || fatal "archive contains an unsafe path"
    mkdir -p "$stage"
    chmod 700 "$stage"
    tar -xzf "$archive_path" -C "$stage" || fatal "release extraction failed"
    [ -x "$stage/$BINARY" ] || fatal "archive is missing the relay executable"
    [ -f "$stage/release-manifest.json" ] || fatal "archive is missing release-manifest.json"

    "$stage/$BINARY" verify-release --target "$target" "$stage" >/dev/null ||
        fatal "offline release verification failed"
    if [ -n "$required_mode" ]; then
        "$stage/$BINARY" verify-release --target "$target" --connection-mode "$required_mode" "$stage" >/dev/null ||
            fatal "release does not support the required managed connection mode"
    fi
    if [ "$stage_only" = 0 ]; then
        acquire_private_setup_lease
        refuse_private_activation
        for private_config in "$config_root" "$HOME/.config/herdr/plugins/config/herdr-mobile-relay.events"; do
            if [ -e "$private_config/tailscale-setup.json" ] || [ -L "$private_config/tailscale-setup.json" ]; then
                private_phase=$("$stage/$BINARY" tailscale-state get "$private_config/tailscale-setup.json" phase) || fatal "unrecognized private setup state"
                [ "$private_phase" = removed ] || fatal "private setup is active or incomplete; use its updater or recovery action"
            fi
        done
    fi
    manifest_version=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$stage/release-manifest.json" | head -1)
    revision=$(sed -n 's/^[[:space:]]*"revision":[[:space:]]*"\([^"]*\)".*/\1/p' "$stage/release-manifest.json" | head -1)
    [ "$manifest_version" = "$version" ] || fatal "release manifest version mismatch"
    [ "$revision" = "$tag_revision" ] ||
        fatal "release manifest revision does not match tag commit"

    releases_dir="$release_root/releases"
    final_dir="$releases_dir/${version}-${revision}-${os}-${arch}"
    previous_dir=
    if [ -L "$release_root/current" ]; then
        previous_link=$(readlink "$release_root/current")
        case "$previous_link" in
            /*) previous_dir=$previous_link ;;
            *) previous_dir="$release_root/$previous_link" ;;
        esac
    fi
    if [ "$stage_only" = 1 ]; then
        write_install_sentinel "$release_root" new
    else
        prepare_install_roots "$release_root" "$config_root" "$cache_root"
    fi
    acquire_install_lock "$release_root"
    mkdir -p "$releases_dir"
    if [ "$stage_only" = 0 ]; then mkdir -p "$shim_dir"; fi
    chmod 700 "$release_root" "$releases_dir"
    if [ -e "$final_dir" ]; then
        "$stage/$BINARY" verify-release --target "$target" "$final_dir" >/dev/null ||
            fatal "existing target release directory is invalid"
    else
        mv "$stage" "$final_dir" || fatal "could not install release directory"
    fi
    "$final_dir/$BINARY" seal-release "$final_dir" ||
        fatal "could not seal installed release directory"
    if [ "$stage_only" = 1 ]; then
        info "Verified release staged without activation: $final_dir"
        printf '%s\n' "$final_dir"
        return 0
    fi
    if [ -n "$previous_dir" ]; then
        "$final_dir/$BINARY" prune-releases "$release_root" "$final_dir" "$previous_dir" ||
            fatal "could not prune obsolete releases"
    else
        "$final_dir/$BINARY" prune-releases "$release_root" "$final_dir" ||
            fatal "could not prune obsolete releases"
    fi
    shim_temp="$shim_dir/.${BINARY}.$$"
    rm -f "$shim_temp"
    ln -s "$release_root/current/$BINARY" "$shim_temp"
    mv -f "$shim_temp" "$shim_dir/$BINARY" ||
        fatal "could not install executable shim"

    "$final_dir/$BINARY" activate-release "$release_root" "$final_dir" ||
        fatal "could not atomically activate the complete release"

    info "Installed ${BINARY} ${version} to $final_dir"
    info "Active release: $release_root/current"
    case ":$PATH:" in
        *":$shim_dir:"*) ;;
        *) printf 'Add %s to PATH.\n' "$shim_dir" >&2 ;;
    esac
}

main "$@"
