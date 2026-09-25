#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-tailscale-native.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/manager.log"
case "$*" in
 '--user show-environment'|'--user daemon-reload') exit 0 ;;
 '--user is-active --quiet herdr-mobile-relay-tailscale.service') exit 3 ;;
 '--user is-enabled --quiet herdr-mobile-relay-tailscale.service') exit 1 ;;
 '--user stop herdr-mobile-relay-tailscale.service'|'--user disable herdr-mobile-relay-tailscale.service') exit 0 ;;
 *) echo 'unexpected service target' >&2; exit 99 ;;
esac
STUB
chmod 700 "$WORK/bin/systemctl"
export PATH="$WORK/bin:$PATH"
for outcome in commit rollback uncertain; do
 export HOME="$WORK/$outcome" OUTCOME="$outcome" REPO_DIR
 export XDG_STATE_HOME="$HOME/.local/state"
 mkdir -p "$HOME/.config/systemd/user" "$HOME/config"
 printf 'original unit\n' > "$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service"
 printf "HERDR_RELAY_INSTANCE_ID='fixture'\n" > "$HOME/config/relay.env"
 cp "$HOME/config/relay.env" "$HOME/env-before"
 if bash -euo pipefail <<'SCRIPT' > "$HOME/output" 2>&1
source "$REPO_DIR/relay/common.sh"
source "$REPO_DIR/relay/native-install-transaction.sh"
native_keep_recovery=true
native_install_pre_restore() {
 echo pre >> "$HOME/hooks"
 [[ "$OUTCOME" != uncertain ]]
}
native_install_post_restore() { printf 'post:%s\n' "$1" >> "$HOME/hooks"; }
unit="$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service"
native_install_begin systemd "$unit" '' "$HOME/config/relay.env" herdr-mobile-relay-tailscale.service ''
native_changed=true
printf 'replacement\n' > "$unit"
printf 'replacement\n' > "$HOME/config/relay.env"
if [[ "$OUTCOME" == commit ]]; then native_install_commit; else exit 1; fi
SCRIPT
 then
  [[ "$outcome" == commit ]] || { echo 'rollback reported success' >&2; exit 1; }
  [[ ! -f "$HOME/hooks" ]]
 else
  [[ "$outcome" != commit ]] || { printf 'native commit failed\n' >&2; exit 1; }
  grep -Fxq 'original unit' "$HOME/.config/systemd/user/herdr-mobile-relay-tailscale.service"
  cmp -s "$HOME/config/relay.env" "$HOME/env-before"
  grep -Fxq pre "$HOME/hooks"
  if [[ "$outcome" == uncertain ]]; then grep -Fxq post:true "$HOME/hooks"; else grep -Fxq post:false "$HOME/hooks"; fi
 fi
 [[ -n "$(find "$XDG_STATE_HOME" -type d -name 'herdr-native-recovery.*' -print -quit)" ]]
 if grep -q 'herdr-remote\|--quiet $' "$HOME/manager.log"; then echo 'unexpected legacy operation' >&2; exit 1; fi
done
echo 'Tailscale native transaction integration tests passed'
