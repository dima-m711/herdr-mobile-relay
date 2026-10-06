# Private Linux setup in this fork

This fork is **Tailscale-first, not Tailscale-only**. Existing explicit gateway/Cloudflare configurations remain alternatives. macOS retains its existing defaults and adds [explicit managed Tailscale setup](tailscale-macos.md). It retains upstream Herdr Mobile Relay attribution and AGPL-3.0-or-later licensing.

## Availability and prerequisites

The implementation is on `feat/tailscale-first-linux`. **This work does not publish a fork release.** The upstream `0.21.3` release is not a private-capable fork bundle. Installation commands require a maintainer-published, checksum/manifest-verified fork release; missing fork releases fail rather than fall back upstream. Development bundle builds are for isolated verification until release/human acceptance is complete.

Supported setup scope: non-root Linux amd64/arm64, systemd user services, standard HOME/XDG/Herdr plugin paths. Install and authenticate Tailscale separately (client 1.52+), connect it, and have Herdr running at the selected local socket. GNU timeout, flock, curl, systemd tools and hashing utilities are required. No Go, Node or Python toolchain is required on the installed host. Development smoke checks use Python to select disposable ports.

Setup never enrolls Tailscale, enables Funnel, changes ACLs/operator/global preferences, opens public fallback tunnels or implicitly enables linger. Serve certificates can disclose the machine hostname through certificate transparency. The user service starts at login; unattended boot requires separately reviewed linger **and** an available Herdr session.

Actual Ubuntu/Arch/Omarchy, privileged Serve and phone acceptance remain human gates. Automated fixtures do not prove those environments passed. Release downloads/checks still contact GitHub, optional notifications use browser push services, and the shared app host must serve trusted code; private relay transport is not a promise that all ancillary traffic stays inside the tailnet.

## New installation

Once a private-capable release is published, install this fork:

```sh
herdr plugin install dima-m711/herdr-mobile-relay
herdr plugin action invoke setup --plugin herdr-mobile-relay.events
```

Fresh Linux installs default to private setup. Review the selected socket, private endpoint, service and scoped Serve command in the private terminal before approving. Existing unmarked/explicit legacy configurations are not silently switched. Custom layouts or unknown existing units require manual migration review.

The first computer can host the app itself. For subsequent computers, enter the **same private app origin** from the first computer. Each relay keeps its own endpoint, key, identity and enrolled credentials. The app-host computer must remain reachable to load/update the shared app; there is no automatic app-host failover.

## Existing approved runbook: first fork bundle

An unmanaged runbook installation cannot use the managed updater yet. From a checked-out copy of this fork, stage a published private-capable bundle without changing `current`, configuration, service or Serve:

```sh
VERSION=REPLACE_WITH_PUBLISHED_FORK_VERSION
candidate=$(HERDR_RELEASE_STAGE_ONLY=1 HERDR_RELEASE_REQUIRED_MODE=tailscale \
  sh ./install.sh "$VERSION")
bash "$candidate/relay/tailscale-setup.sh" \
  --adopt-runbook --release-directory "$candidate" --no-pair
```

Run this in your own private interactive terminal. Only the exact recognized runbook unit/launcher, original environment and matching endpoint are accepted. The adoption summary explicitly includes stopping that service and activating the staged bundle. Approved adoption snapshots unit/environment/activation and old/new release paths before cutover. It retains existing credentials and the adopted route. A caught failure restores the previous release before restarting its original service. Unknown units, public origins, modified state and externally changed pointers are refused.

Do **not** manually switch `current` to bypass adoption. If the adoption is interrupted, retain both releases and use the staged script and candidate path recorded above:

```sh
bash "$candidate/relay/tailscale-setup.sh" --recover --release-directory "$candidate"
```

Recovery is separately approved and validates retained private evidence. `--keep-route` is only for explicitly reviewed route uncertainty; it is not permission to discard identity checks. Failed or ambiguous restoration keeps its evidence for owner review.

## Pairing, operation and shared app origins

Installed scripts are under `~/.local/share/herdr-mobile-relay/current/relay/`.

- `tailscale-pair.sh`: verify the selected relay and app host, then explicitly arm/display one invitation in an attached private terminal. Never copy the QR or fragment into logs, screenshots, tickets or chat. Invitations expire after ten minutes without automatic renewal; existing phones are retained.
- `tailscale-pair.sh --choose-app`: review a different private app origin. The change is staged, consent-checked, restarted and verified; previous allowed origins and device credentials are retained. Existing browser storage does not migrate automatically between app origins.
- `tailscale-control.sh start|restart|stop|status|logs`: operate only the verified private service. Ordinary service control neither provisions Serve nor arms pairing. Status reports local/HTTPS identity separately from phone authentication.
- Setup accepts `--no-pair`; Quick Start displays pairing only with a private terminal. Narrow terminals give a private-link/widening instruction instead of an unusable QR.
- `tailscale-teardown.sh`: separately approved scoped teardown; created routes are removed only with current ownership evidence, while adopted routes and credentials remain. Full uninstall is a different destructive action and requires legitimate ownership sentinels. Adoption does not authorize claiming a preexisting directory for deletion.

Phone acceptance means authenticated inventory and an actual safe control action from the phone—not merely a green local health check or rendered QR.

## Managed updates and interruption

After adoption, the fork plugin update path uses the shared lifecycle lock, verifies old/new private bundle capabilities and exact runtime identity, and preserves environment, unit, device-auth, app origin, enablement and Serve. Inactive installations stay inactive. Private updates refuse Cloudflare app-first deployment; update the shared app-host relay separately to update its app bundle.

Failures attempt rollback only while release/configuration/service identities still belong to the attempt. `update-recovery.*` and `app-origin-recovery.*` directories are private evidence, not executable shell files. Do not source them or paste their contents into support requests.

These two interrupted-change flows deliberately require owner review rather than automatic replay: privately compare the retained old/new configuration or release paths, reconcile the chosen configuration/current pointer and verified service, then move evidence aside **only after verification**. Do not delete evidence just to unblock a command. Setup adoption recovery uses its dedicated `--recover` flow instead. Diagnostics and stop remain available for pending managed updates; new updates, invitations and lifecycle changes fail closed.

Missing Tailscale/app-host connectivity, renamed hosts and unfamiliar manager definitions never trigger public fallback. Restore the original identity or conduct a separately reviewed migration.

## Acceptance and rollout checklist

Do not deploy an unpublished checkout over a working installation. First prepare
a distinct, private-capable fork release and retain its verified previous bundle.
Treat this checklist as **outstanding human signoff**, not results of the mock tests:

1. On disposable Ubuntu and Arch/Omarchy hosts (amd64 and arm64 where available),
   test fresh setup, cancellation, missing/logged-out Tailscale and noninteractive
   refusal. Confirm no enrollment, policy changes, public route or fallback.
2. In a private terminal, review the exact Serve command and complete any HTTPS
   consent yourself. Test operator access and the separately approved sudo path.
   Check the loopback listener and selected user unit without publishing secrets.
3. On the phone with Tailscale connected, install/open the app from host A, pair A,
   then pair B using A's same app origin. Confirm separate computer identities,
   authenticated inventory and a harmless control action on each. Tailnet
   connectivity or a rendered QR alone is not acceptance.
4. Close/reopen the installed app and restart each relay; retained credentials
   must reconnect without a new QR. A consumed or ten-minute-old invitation must
   fail; explicitly displaying a new one must not revoke existing devices.
5. Disconnect phone Tailscale and separately make B unreachable. Confirm clear
   connection failure without a gateway/public fallback. Stop app host A and
   check that inability to load/update the shared app is not misreported as B
   being unpaired. Do not clear browser storage as a recovery technique.
6. After private backups and separate deployment approval, test exact runbook
   adoption, managed update success and controlled failure/rollback. Compare
   device data, service enablement, app origin and Serve ownership before/after.
   Keep interrupted-change evidence private; use the documented recovery path.
7. Test logout/login and reboot expectations. Without separately approved linger,
   no unattended service start is promised. Even with linger, an available Herdr
   session is required. Confirm macOS/explicit legacy alternatives are unchanged.
8. Test teardown on disposable created and adopted routes: remove only verified
   created routes, retain adopted routes and pairings. Full deletion requires a
   separate sentinel-backed confirmation. Never use a production phone pairing
   or route to exercise destructive tests.

Automated coverage is deliberately layered: setup/update shell tests use fake
managers and endpoints; compiled pairing tests exercise an isolated real
SIGUSR1 acknowledgment; device-auth tests cover invitation lifetime and retained
credentials; browser journeys use intercepted synthetic private origins and
mock sockets to prove independent credential selection, storage retention and
no public fallback. These do not simulate Tailscale's daemon, privileged Serve,
certificate issuance or a physical installed phone. Browser app-host outage
coverage uses a synthetic HTTP 503, not an offline-cache availability guarantee.
