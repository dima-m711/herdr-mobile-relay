# Tailscale-first Linux: acceptance evidence

Repository implementation and isolated automation are distinct from release and
live deployment acceptance. No fork release is published by this change; no
installed relay, paired phone or live tailnet is migrated by these tests.

## Requirements and automated layers

| Plan acceptance | Evidence in the repository | What it does not establish |
| --- | --- | --- |
| AE1: fresh guided private setup | `tests/test_tailscale_setup.sh`, `test_tailscale_entrypoints.sh`, `test_tailscale_defaults.sh`, `test_tailscale_pairing.sh` | Real systemd session, certificate consent or phone scan |
| AE2: missing prerequisites fail closed | `internal/setuphelper/tailscale_test.go`, `test_tailscale_context.sh`, `test_tailscale_common.sh` | Every Tailscale client/daemon version |
| AE3: conflict/ownership protection | `test_tailscale_setup.sh`, `test_tailscale_consent.sh`, state/preflight Go tests | Atomicity against arbitrary administrator writes between checks |
| AE4: retained identities/pairings | `tests/blackbox/tailscale_test.go`, `internal/deviceauth/private_test.go`, setup/bootstrap/update shell fixtures and browser reload/reopen cases | A physical installed PWA or production migration |
| AE5: shared app A, independent relays A/B | Two real private relay processes in `tests/blackbox/tailscale_test.go`; pairing shell and synthetic private-origin browser cases | Real two-host tailnet HTTPS availability |
| AE6: no public fallback | Runtime configuration tests, disabled-gateway black-box assertions, missing endpoint/policy shell cases, browser reconnect URLs | Tailscale daemon internals, tailnet ACLs or router state |
| AE7: explicit short-lived invitation | Device-auth tests, real isolated SIGUSR1 acknowledgment in `tailscale_pairing_test.go`, failed-arm/display shell cases | Physical QR readability or installed-phone enrollment |
| AE8: transport intent and fork updates | Default/entrypoint/plugin/native/staging/update/bootstrap shell tests; release manifest and worker Go tests | Successful download of a not-yet-published fork release |

The real-process private test exercises encrypted WebSocket enrollment and
credential authentication, shared cross-origin access, separate fake Herdr
socket inventories and process restarts. Its HTTP/WebSocket connections are
loopback fixtures, not Tailscale HTTPS. Browser tests intercept synthetic
`*.fixture.ts.net` names before DNS and use mock sockets. App-host failure is a
synthetic HTTP 503; it is not an offline-cache availability guarantee.

Failure injection covers cancellation/EOF, malformed or foreign state, unsafe
units/paths, permission/Serve/HTTPS failures, rollback, unrelated routes,
SIGKILL interruption, consent-time identity changes and installer/update lease
contention. The standalone installer also refuses a private setup introduced
while its download is in progress and reuses an inherited lifecycle lease
without releasing its ancestor's lock.

## Reproduce repository gates

Use Go 1.27.0, Bun 1.4.0 and Node, install frontend dependencies with
`bun install --frozen-lockfile --cwd frontend`, and install the pinned Chromium
and WebKit builds with their host dependencies in a development environment.
Then run `make check`. This includes formatting/vet, all Go tests/race checks,
shell/native-manager fixtures, production-path audit, frontend lint/typecheck/
unit/build/size checks, shipped-web browser journeys, real-relay attention
browser cases, four-target cross-builds and bundle/native smoke verification.
Existing PR CI jobs include the new tests through these targets; no tailnet
credentials or new privileged CI job is required.

For a workstation with a live relay, isolate HOME, agent variables and PATH;
clear inherited XDG overrides so nested fixture homes get their own defaults.
Retain the original GOPATH/GOCACHE, use `TMPDIR=/tmp` for short Unix socket
paths, and expose only pinned Go/Bun plus a Node-only shim and system tools.
Do not run an installed agent wrapper for version discovery. Do not use
`make web-release` as verification: it intentionally increments asset versions.

Exact final revision, command and results belong in the PR validation section.
The local completion record additionally retains a fresh-shell verification
script, browser libraries/dependencies and run-specific environment/log files.
No independent-review claim is made: review was direct, with reproduced
regressions and subsequent fixes.

## Human release/deployment gates — NOT RUN by this work

Use the eight-step [private rollout checklist](tailscale-linux.md#acceptance-and-rollout-checklist).
A maintainer owns publishing a distinct verified fork bundle; the operator owns
separate authorization for real Ubuntu/Arch/Omarchy amd64/arm64 setup, privileged
Serve/TLS, login/reboot/linger, two-host availability and physical iPhone/Android
pairing/control/reconnect. Native macOS/arm64 execution is not claimed by local
cross-builds. Existing explicit legacy/macOS alternatives remain supported;
native macOS Tailscale setup is deferred.

Keep private recovery evidence until reconciliation succeeds. Interrupted
app-origin changes and managed updates deliberately need owner review; there is
no automatic replay or app-host failover. An adopted Serve route is retained by
teardown. Full data deletion needs separate ownership evidence and confirmation.
Never upload real QR fragments, device credentials or recovery files with a PR.
