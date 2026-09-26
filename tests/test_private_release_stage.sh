#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d /tmp/herdr-private-stage.XXXXXX)
trap 'result=$?; if [[ $result != 0 && -f "$WORK/error" ]]; then tail -25 "$WORK/error" >&2; fi; chmod -R u+w "$WORK"; rm -rf "$WORK"; exit "$result"' EXIT
REVISION=1111111111111111111111111111111111111111
# Build before replacing HOME; never discover agent tools or real service state.
mkdir -p "$WORK/bundle/web" "$WORK/bundle/relay"
CGO_ENABLED=0 go build -trimpath -ldflags "-X main.version=1.2.3 -X main.revision=$REVISION" -o "$WORK/bundle/herdr-mobile-relay" "$REPO_DIR/cmd/herdr-mobile-relay"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" XDG_DATA_HOME="$WORK/home/.local/share" XDG_CACHE_HOME="$WORK/home/.cache" XDG_STATE_HOME="$WORK/home/.local/state" XDG_RUNTIME_DIR="$WORK/home/runtime"
unset GH_TOKEN GITHUB_TOKEN HERDR_RELEASE_REPOSITORY HERDR_RELEASE_BASE_URL
mkdir -p "$HOME/.local/bin" "$XDG_RUNTIME_DIR"
export PATH="$HOME/.local/bin:$PATH" STAGE_WORK="$WORK"
cat > "$HOME/.local/bin/curl" <<'STUB'
#!/bin/bash
set -eu
output=-
while [[ $# -gt 0 ]]; do
 case "$1" in --output) output="$2"; shift ;; https://*) url="$1" ;; esac
 shift
done
printf '%s\n' "$url" >> "$STAGE_WORK/requests"
case "$url" in
 https://api.github.com/repos/dima-m711/herdr-mobile-relay/commits/v1.2.3) data="$STAGE_WORK/commit.json" ;;
 https://github.com/dima-m711/herdr-mobile-relay/releases/download/v1.2.3/checksums.txt) data="$STAGE_WORK/checksums.txt" ;;
 https://github.com/dima-m711/herdr-mobile-relay/releases/download/v1.2.3/*.tar.gz) data="$STAGE_WORK/archive.tar.gz" ;;
 *) echo 'unexpected release owner or URL' >&2; exit 99 ;;
esac
if [[ "${STAGE_INTRODUCE_PRIVATE:-}" == 1 && "$data" == "$STAGE_WORK/archive.tar.gz" ]]; then
 mkdir -p "$HOME/.config/systemd/user"
 printf 'private setup appeared during download\n' > "$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service"
fi
if [[ "$output" == - ]]; then cat "$data"; else cp "$data" "$output"; fi
STUB
for command in herdr tailscale systemctl; do
 printf '#!/bin/sh\necho "unexpected service/network command" >&2\nexit 99\n' > "$HOME/.local/bin/$command"
done
chmod 700 "$HOME/.local/bin/"*
printf '{"sha":"%s"}\n' "$REVISION" > "$WORK/commit.json"
printf '<html></html>\n' > "$WORK/bundle/web/index.html"
printf 'fixture\n' > "$WORK/bundle/LICENSE"
printf 'fixture\n' > "$WORK/bundle/README.md"
for helper in common herdr-mobile-relay-service plugin-on-event setup-link stable-setup stable-teardown start; do
 printf '#!/bin/sh\n' > "$WORK/bundle/relay/$helper.sh"
done
case $(uname -m) in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) exit 0 ;; esac
case $(uname -s) in Linux) OS=linux ;; Darwin) OS=darwin ;; *) exit 0 ;; esac
"$WORK/bundle/herdr-mobile-relay" release-manifest "$WORK/bundle" 1.2.3 "$REVISION" "$OS/$ARCH" >/dev/null
tar -C "$WORK/bundle" -czf "$WORK/archive.tar.gz" .
if command -v sha256sum >/dev/null; then hash=$(sha256sum "$WORK/archive.tar.gz"); else hash=$(shasum -a 256 "$WORK/archive.tar.gz"); fi
printf '%s  herdr-mobile-relay_1.2.3_%s_%s.tar.gz\n' "${hash%% *}" "$OS" "$ARCH" > "$WORK/checksums.txt"
export INSTALL_ROOT="$XDG_DATA_HOME/herdr-mobile-relay" BIN_DIR="$HOME/.local/bin"
export HERDR_RELAY_ENV="$XDG_CONFIG_HOME/herdr/plugins/config/herdr-mobile-relay.events/relay.env"
# This is a legitimate newly-created release root, not an ownership inference.
sed '$d' "$REPO_DIR/install.sh" > "$WORK/functions.sh"
. "$WORK/functions.sh"
write_install_sentinel "$INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT/releases/previous" "${HERDR_RELAY_ENV%/*}/device-auth"
ln -s releases/previous "$INSTALL_ROOT/current"
printf 'old release\n' > "$INSTALL_ROOT/releases/previous/keep"
printf 'HERDR_CONNECTION_MODE=tailscale\n' > "$HERDR_RELAY_ENV"
printf 'existing device\n' > "${HERDR_RELAY_ENV%/*}/device-auth/keep"
chmod 600 "$HERDR_RELAY_ENV"
cp "$HERDR_RELAY_ENV" "$WORK/original.env"
# The existing fixture is intentionally a valid legacy-only bundle.
if HERDR_RELEASE_STAGE_ONLY=1 HERDR_RELEASE_REQUIRED_MODE=tailscale sh "$REPO_DIR/install.sh" 1.2.3 > "$WORK/output" 2> "$WORK/error"; then
 echo 'legacy bundle passed private capability gate' >&2; exit 1
fi
[[ "$(readlink "$INSTALL_ROOT/current")" == releases/previous ]]
HERDR_RELEASE_STAGE_ONLY=1 sh "$REPO_DIR/install.sh" 1.2.3 > "$WORK/output" 2> "$WORK/error"
STAGED="$(< "$WORK/output")"
[[ -x "$STAGED/herdr-mobile-relay" && "$STAGED" == "$INSTALL_ROOT/releases/1.2.3-$REVISION-$OS-$ARCH" ]]
[[ "$(readlink "$INSTALL_ROOT/current")" == releases/previous ]]
[[ -f "$INSTALL_ROOT/releases/previous/keep" && ! -e "$BIN_DIR/herdr-mobile-relay" && ! -e "$XDG_CACHE_HOME/herdr-mobile-relay" ]]
cmp "$HERDR_RELAY_ENV" "$WORK/original.env"
[[ "$(< "${HERDR_RELAY_ENV%/*}/device-auth/keep")" == 'existing device' ]]
[[ ! -e "${HERDR_RELAY_ENV%/*}/.herdr-mobile-relay-installation" ]]
requests=$(wc -l < "$WORK/requests")
if sh "$REPO_DIR/install.sh" 1.2.3 > "$WORK/output" 2> "$WORK/error"; then echo 'standalone private activation accepted' >&2; exit 1; fi
[[ "$(wc -l < "$WORK/requests")" == "$requests" ]]
if [[ "$OS" == linux ]]; then
 exec 8>> "$INSTALL_ROOT/.install.lock"
 flock -n 8
 if HERDR_RELEASE_STAGE_ONLY=1 sh "$REPO_DIR/install.sh" 1.2.3 > "$WORK/output" 2> "$WORK/error"; then echo 'concurrent staging accepted' >&2; exit 1; fi
 flock -u 8; exec 8>&-
fi
[[ "$(readlink "$INSTALL_ROOT/current")" == releases/previous ]]
if [[ "$OS" == linux ]]; then
 # A different operation can complete private setup while an old installer downloads.
 chmod -R u+w "$INSTALL_ROOT/releases/previous"
 rm -rf "$INSTALL_ROOT/releases/previous"
 cp -R "$STAGED" "$INSTALL_ROOT/releases/previous"
 printf 'HERDR_RELAY_TOKEN=0123456789abcdef0123456789abcdef\n' > "$HERDR_RELAY_ENV"
 if STAGE_INTRODUCE_PRIVATE=1 sh "$REPO_DIR/install.sh" 1.2.3 > "$WORK/output" 2> "$WORK/error"; then
  echo 'standalone installer activated over private setup created during download' >&2; exit 1
 fi
 grep -q 'private installations require' "$WORK/error"
 [[ "$(readlink "$INSTALL_ROOT/current")" == releases/previous ]]
 rm "$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service"
 # A custom legacy target must not hide incomplete state in the private root.
 printf '{}\n' > "${HERDR_RELAY_ENV%/*}/tailscale-setup.json"
 chmod 600 "${HERDR_RELAY_ENV%/*}/tailscale-setup.json"
 if HERDR_RELAY_ENV="$HOME/.config/custom-legacy/relay.env" sh "$REPO_DIR/install.sh" 1.2.3 > "$WORK/output" 2> "$WORK/error"; then
  echo 'custom legacy target bypassed private setup state' >&2; exit 1
 fi
 grep -q 'unrecognized private setup state' "$WORK/error"
 rm "${HERDR_RELAY_ENV%/*}/tailscale-setup.json"
 # Same lease as first setup, including inherited-open-description reuse.
 exec 7>> "${HERDR_RELAY_ENV%/*}/.setup.lock"
 flock -n 7
 if sh "$REPO_DIR/install.sh" 1.2.3 > "$WORK/output" 2> "$WORK/error"; then
  echo 'standalone installer bypassed private lifecycle lease' >&2; exit 1
 fi
 grep -q 'another private lifecycle change' "$WORK/error"
 [[ "$(readlink "$INSTALL_ROOT/current")" == releases/previous ]]
 HERDR_RELAY_SETUP_LOCK_FD=7 sh "$REPO_DIR/install.sh" 1.2.3 > "$WORK/output" 2> "$WORK/error"
 [[ "$(realpath "$INSTALL_ROOT/current")" == "$STAGED" ]]
 if flock -n "${HERDR_RELAY_ENV%/*}/.setup.lock" true; then echo 'child released ancestor lease' >&2; exit 1; fi
 flock -u 7; exec 7>&-
 [[ "$(< "${HERDR_RELAY_ENV%/*}/device-auth/keep")" == 'existing device' ]]
fi
echo 'Fork-owned staging and private activation guard fixtures passed'
