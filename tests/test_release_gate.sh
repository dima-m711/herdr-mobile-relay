#!/bin/sh
set -eu
REPO_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/herdr-release-gate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/scripts" "$WORK/bin"
cp "$REPO_DIR/Makefile" "$WORK/Makefile"
printf 'version = "0.0.0"\n' > "$WORK/herdr-plugin.toml"
# The final smoke command succeeds deliberately: earlier failures must not be
# masked by its exit code. No real bundles, installed hosts or Go tools needed.
printf '#!/bin/sh\necho fake\n' > "$WORK/bin/go"
printf '#!/bin/sh\necho smoke > smoke-ran\n' > "$WORK/scripts/check-installed-release.sh"
printf '%s\n' '#!/bin/sh' 'set -eu' \
    '[ "$GATE_CASE" != package-failure ] || exit 42' \
    'mkdir -p "$3/content/relay"' \
    '[ "$GATE_CASE" = missing-helper ] || printf "#!/bin/sh\\n" > "$3/content/relay/native-install-transaction.sh"' \
    'for n in 1 2 3 4; do' \
    '    if [ "$n" = 4 ] && [ "$GATE_CASE" = missing-archive ]; then continue; fi' \
    '    tar -C "$3/content" -czf "$3/herdr-mobile-relay_$n.tar.gz" .' \
    'done' \
    '[ "$GATE_CASE" = empty-checksum ] || echo checksum > "$3/checksums.txt"' \
    'exit 0' > "$WORK/scripts/package-release.sh"
chmod +x "$WORK/bin/go" "$WORK/scripts/"*.sh
for GATE_CASE in package-failure missing-archive empty-checksum missing-helper; do
    export GATE_CASE
    if PATH="$WORK/bin:$PATH" make -C "$WORK" release-bundle-check > "$WORK/output" 2>&1; then
        echo "release gate masked $GATE_CASE" >&2
        exit 1
    fi
    test ! -e "$WORK/smoke-ran"
done
GATE_CASE=success PATH="$WORK/bin:$PATH" make -C "$WORK" release-bundle-check > "$WORK/output" 2>&1
test -s "$WORK/smoke-ran"
echo 'release bundle gate fails closed before native smoke'
