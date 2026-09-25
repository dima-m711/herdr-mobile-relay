#!/bin/bash
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HERDR_RELAY_ENV="$HOME/.config/herdr/plugins/config/herdr-mobile-relay.events/relay.env"
unset HERDR_SESSION HERDR_CLIENT_SOCKET_PATH

set -a
source "$HERDR_RELAY_ENV"
set +a

: "${HERDR_RELAY_TOKEN:?Missing relay key}"
: "${HERDR_RELEASE_ROOT:?Missing release path}"
: "${HERDR_SOCKET_PATH:?Missing Herdr socket selection}"

if [ "${#HERDR_RELAY_TOKEN}" -ne 32 ] || [ -n "${HERDR_GATEWAY_URL:-}" ]; then
  echo "Expected a 32-byte relay key and no external gateway. Check relay.env." >&2
  exit 1
fi

export HERDR_RELAY_HOST=127.0.0.1
export HERDR_GATEWAY_URL=
export HERDR_REACHABILITY_PORT_MAPPING=0
export HERDR_TRANSPORT_FORCE_RELAY=1
export HERDR_RELAY_REARM_BOOTSTRAP=0

exec "$HERDR_RELEASE_ROOT/current/herdr-mobile-relay" serve
