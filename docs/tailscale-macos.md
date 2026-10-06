# Private Tailscale access on macOS

This fork adds an explicit **Tailscale Private Setup** option for Apple Silicon
and Intel Macs. It uses a per-user LaunchAgent, not a root daemon. Existing
macOS Cloudflare/gateway defaults and selected transports are not silently
changed. A failed private setup never falls back to a public transport.

## Availability and prerequisites

This is development-branch support. A PR or plugin-source checkout is **not** a
published native release. Normal plugin installation requires a fork release
whose macOS bundle advertises `tailscale_setup: 1` and includes the complete
private backend. Older upstream/macOS bundles do not qualify. This work does
not publish a release or deploy an upgrade.

- Sign into the Mac's desktop as an ordinary user. SSH-only/headless sessions
  without a GUI launchd domain and root installation are not supported.
- Run Herdr and use its standard `~/.config/herdr` configuration/socket layout.
  Custom HOME/XDG/plugin/release layouts require a separate migration review.
- Install and connect Tailscale separately, on both the Mac and phone.
  Tailscale 1.52 or newer and its `tailscale` **CLI integration** must be
  available in PATH. The standalone Mac app offers CLI integration in Settings.
  Setup does not install Tailscale, enroll devices, change ACLs or enable Funnel.
- Stock macOS Bash, `launchctl`, `plutil`, `lsof` and `curl` are used. The verified
  relay supplies locking, hashing, canonical paths and bounded command execution;
  no Homebrew GNU utilities, Go, Node, Python or jq are needed on the installed host.

Tailscale Serve proxies the relay's loopback HTTP port; it does not serve local
files directly. The Mac App Store/standalone app restriction on file serving is
therefore not a blocker. See [Tailscale Serve](https://tailscale.com/docs/reference/examples/serve)
and [macOS CLI integration](https://tailscale.com/docs/reference/tailscale-cli).

## Installation and pairing

Once a suitable fork release is published:

```sh
herdr plugin install dima-m711/herdr-mobile-relay
```

Choose **Tailscale Private Setup** explicitly in the setup menu. Review the
selected Herdr session, private HTTPS endpoint and scoped Serve command in your
private terminal before approving. The service uses:

- `~/Library/LaunchAgents/com.herdr-mobile-relay.tailscale.plist`
- `~/.config/herdr/plugins/config/herdr-mobile-relay.events/relay.env`
- `~/.local/share/herdr-mobile-relay/current`

Setup refuses conflicting legacy relay services; it does not adopt arbitrary
Mac plists or change an existing gateway configuration. `--adopt-runbook` remains
Linux-only. Review and explicitly remove/migrate an existing transport first;
do not delete device credentials to force setup through.

The default private URL is `https://<machine>.<tailnet>.ts.net:8443`. HTTPS
certificate issuance exposes the DNS name in public certificate-transparency
logs. Tailnet membership and access rules still apply.

If your phone already uses the app hosted by another computer, select that same
private **app origin** during setup. Each relay keeps its own device credentials.
The app host must stay reachable; there is no automatic host failover.

To request a new single-use invitation later, in your private attached terminal:

```sh
bash ~/.local/share/herdr-mobile-relay/current/relay/tailscale-pair.sh
```

The helper verifies the loaded job, running executable, loopback listener and
private HTTPS identity before requesting and confirming a fresh invitation.
QRs are not written to service logs. Adding a phone does not revoke other phones.

## Service and lifecycle

```sh
bash ~/.local/share/herdr-mobile-relay/current/relay/tailscale-control.sh status
bash ~/.local/share/herdr-mobile-relay/current/relay/tailscale-control.sh stop
bash ~/.local/share/herdr-mobile-relay/current/relay/tailscale-control.sh start
bash ~/.local/share/herdr-mobile-relay/current/relay/tailscale-control.sh restart
bash ~/.local/share/herdr-mobile-relay/current/relay/tailscale-control.sh logs
```

Stop unloads only the owned job; it does not delete its plist, disable login
startup, reset credentials or remove Serve. Start/restart do not change an
administrator's disabled-job override. Logs append to the private config
folder's `tailscale-relay.log`; no system journal or external log collector is
required. Review/rotate that file if needed.

The LaunchAgent starts at GUI login. A logged-out or sleeping Mac may be
unreachable. Setup does not prevent sleep, create a boot-time daemon or restart
Herdr/Tailscale.

Private updates preserve the selected service, enablement, environment, app
origin, device credentials and Serve route. A stopped service stays stopped.
Failed cutovers restore the previous release only while ownership still matches.
Unknown cached launchd jobs, replaced locks and changed definitions fail closed.

Teardown is a separate approved action:

```sh
bash ~/.local/share/herdr-mobile-relay/current/relay/tailscale-teardown.sh
```

It retains credentials and adopted/external routes, removing only this managed
service and its still-owned created route. Incomplete setup can use
`tailscale-setup.sh --recover`; **a verified setup cannot use recovery as undo**.
Preserve any `update-recovery.*` or `app-origin-recovery.*` evidence for owner
review rather than deleting it to bypass a safety check.

## Verification boundary

Deterministic tests exercise launchd snapshots, drift rejection, service intent,
FD locking, release capabilities and Linux regression behavior. Cross-building a
Darwin binary is not proof that a real Mac's launchd/lsof/Tailscale behavior works.
Before treating this as production-ready, run native acceptance on macOS:

1. Test a clean GUI-session install and explicit cancellation with a real Mac
   Tailscale client; verify no unrelated service or Serve route changes.
2. Pair a phone, perform a harmless Herdr action, reopen the app, and restart the
   relay without another QR. Test a shared app origin with a second relay.
3. Test stop/start, logout/login, sleep/wake and Tailscale outages; verify private
   reconnection and no public fallback or automatic invitation.
4. Test active and stopped updates, failed-start rollback, interrupted setup
   recovery, identity-drift refusal, teardown and explicit transport departure.
5. Cover both Apple Silicon and Intel; identify the Tailscale client variant.

For native developer tests, use an isolated HOME and a canonical temporary path
(e.g. `/private/tmp`, not its `/tmp` symlink), with Go/Bun installed only for
building/testing. Do not run failure fixtures against a live user service.
