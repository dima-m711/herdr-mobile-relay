---
title: "feat: Verify private relay adoption on the existing host"
type: feat
status: active
date: 2026-09-27
execution_posture: checkpointed-live-acceptance
---

# Private relay live acceptance on minibox

## Goal and current facts

Validate the fork on the user's actual Linux computer and physical phone, preserving the working installation and providing an explicit backout path. **Do not uninstall the old plugin.** This is a new operational plan, not a revision of the completed implementation plan.

Planning-time read-only observations:
- The registered `herdr-mobile-relay.events` plugin is enabled and reports version `0.21.3`.
- The installed release pointer resolves to upstream `0.21.3`, revision `a58f1fc63469995534f4ae7de8e55220ce10ffaa`, Linux amd64.
- PR #1 is open at `84c44468983b58d9e60cf2f3fe070dbcb6e08c88`; its check rollup is empty. This does not establish why CI has not reported results.
- The fork currently has no published releases. Existing copied upstream tags must not be reused or moved.
- Herdr terminal control is available. The installed CLI supports explicit plugin `--ref` and creating an unfocused labeled tab.
- Service activity, live Serve state, current phone connectivity and backup restorability have **not** been revalidated during planning.

The user selected **a fork prerelease** as the test distribution approach. This approves the plan's direction, not publication, live cutover, sudo or reboot now.

## Requirements and scope

### Preserve the working installation
- R1: Retain the existing relay identity, enrolled phone, app origin, selected endpoint, old verified bundle and unrelated Serve configuration.
- R2: Stage before activation; adopt only the exact recognized runbook installation. Unknown metadata or drift stops the test rather than weakening checks.
- R3: Keep private backups and usable recovery instructions; do not claim that setup recovery is a general downgrade command.

### Establish actual evidence
- R4: Exercise published fork assets, native Linux systemd/Serve/TLS, installed phone authentication and harmless control, not just health checks.
- R5: Exercise new-device invitation, restart/reopen retention, outages, plugin entrypoints and explicit-version managed updates without risking unrelated sessions.
- R6: Distinguish this machine's acceptance from fresh-install, two-host, other-platform, destructive and stable-channel acceptance.

### Keep the operator in control
- R7: Separate publication, live service downtime, privileged changes, and logout/reboot approvals. Passwords and pairing material stay in private terminals.
- R8: Record candidate versions/revisions, outcomes and retained artifacts. Never upload credentials, invitations, raw recovery records or live inventory.

Non-goals: uninstall/reinstall from scratch on the production account; global Tailscale changes; main-branch merge or stable promotion; upgrading/restarting the main Herdr server; re-testing unrelated application features; claiming every supported platform passed on one host.

## Decisions and sequencing

| Decision | Reason / boundary |
| --- | --- |
| Publish a distinct fork prerelease, not an upstream-tag replacement | Exercises real asset discovery/download and capability checks without announcing stable readiness. |
| Adopt the existing runbook before replacing plugin source | Initial upstream installations lack the managed private state required by the new plugin update path. |
| Keep the existing app origin and phone storage | An origin change would confound credential-preservation testing; clearing storage destroys the evidence. |
| Test the existing phone before new pairing | Re-enrollment must not conceal migration failure. |
| Use a second, distinct prerelease for real update cutover | Installing the same bundle exercises only the no-op path. |
| Keep crashes and destructive tests disposable | Failure injection must not target the working phone, live Herdr session or production route. |

Sequence: **T1 baseline/recovery → T2 verified prerelease → T3 stage/cancel/adopt → T4 retained-phone proof/plugin integration → T5 pairing/outages → T6 managed update → T7 boot/disposable matrix → T8 signoff**.

This is operational acceptance, not eight implementation commits. Only necessary version/release-preparation changes, discovered regression fixes and sanitized evidence need repository changes. Any fix gets its own regression test and re-verification; do not modify an already-tested release asset or move its tag.

## Execution units

### [ ] T1 — Establish baseline, private backups and backout readiness

**Requirements:** R1–R3, R7–R8. **Dependencies:** execution approval; user available with the currently paired phone.

**Reference files:** `docs/tailscale-linux.md`, `relay/tailscale-common.sh`, `relay/tailscale-transaction.sh`, `relay/native-install-transaction.sh`, `tests/fixtures/tailscale-runbook.service`, `tests/fixtures/tailscale-runbook-launcher.sh`.

**Approach:**
- Create one clearly labeled Herdr operations tab without stealing focus. Use returned explicit IDs, never whichever pane happens to be focused. Keep a local terminal recovery path independent of mobile access.
- Read only necessary metadata: actual OS/architecture/tool versions, verified release and plugin source/ref, exact unit/launcher and manager identity, active/enabled state, linger, listener ownership, configured socket, selected Serve route and unrelated-route digest. Parse secrets locally without printing their contents. Do not dump the environment, process arguments, full journal or session inventory.
- Have the user confirm the old installed phone app currently authenticates and can operate a disposable test tab. Record the baseline app and relay versions separately.
- Back up the old bundle, plugin source/registration, environment, launcher, exact unit, device-auth state and existing lifecycle/recovery metadata into an owner-only directory outside Git. Store Serve observations privately for comparison, not as a future full-reset command. Verify readability, completeness, permissions and the old bundle's manifest.
- Make the final snapshot consistent in an approved short maintenance window: quiesce phone writes, stop only the positively identified relay if needed, capture device state, and restore the original service so adoption's active-runtime preflight can succeed. No unapproved downtime during baseline inspection.
- Before cutover, prepare an operator-reviewed restoration procedure using the verified originals. Include service activation/enablement, release pointer, plugin registration and fork-created state bookkeeping. Restoration must recheck current ownership, stop only the affected relay, restore the original bundle/definitions before restarting it, and verify the phone again. Never reset all Serve configuration or blindly overwrite newer device credentials/revocations.

**Scenarios / gate:** old phone works; exact runbook identity matches; a missing/unsafe backup or mismatched unit blocks cutover. Record the proposed maintenance window and recovery instructions before proceeding. A backup alone is not proof of a tested restore; rehearse restore mechanics in an isolated copy and label live restoration unproven until exercised.

### [ ] T2 — Prepare and publish an immutable test prerelease

**Requirements:** R4, R7–R8. **Dependencies:** user approval for repository changes and publication; T1 inventory informs the target. No live activation.

**Reference/change candidates:** `herdr-plugin.toml`, `web/version.json`, `frontend/scripts/release.mjs`, `scripts/package-release.sh`, `.github/workflows/check.yml`, `.github/workflows/release.yml`. **Tests:** existing `make check` targets, `tests/test_release_gate.sh`, `tests/test_private_release_stage.sh`, `scripts/check-installed-release.sh`.

**Approach:**
- Pick an unused numeric version, provisionally `0.21.4`, after rechecking fork tags/releases. Do not use an `-rc` suffix: current private updater/version checks require `MAJOR.MINOR.PATCH`; GitHub's prerelease flag carries the candidate status.
- Follow the repository's version/build procedure so plugin, binary and shipped web metadata agree. Freeze the source SHA, review the diff and commit intended changes before the clean-tree verification script. Keep existing verification prerequisites and logs intact.
- Investigate absent PR checks. If Actions/settings permissions need changes, ask the owner; do not disable gates. Obtain a successful check workflow associated with the candidate SHA plus the isolated full local gate. Preserve failed-run diagnostics rather than representing no checks as a pass.
- After explicit publication approval, use the existing tagged-release pipeline. It already marks commits not contained in `main` as prereleases and requires check/native-smoke jobs. Retain all four bundles and checksums. Verify the resulting tag/SHA, prerelease flag, repository, exact version, complete assets and private capability.
- Do not merge to main, promote to latest/stable, retag an upstream release, or replace candidate assets in place. A discovered defect requires a new candidate version.

**Scenarios / gate:** bad/missing assets or mismatched revision block download/adoption; successful native smoke and published private-capable Linux archive are required. This machine must continue running its old installation throughout this phase.

### [ ] T3 — Stage, reject once, then adopt the recognized runbook

**Requirements:** R1–R4, R7–R8. **Dependencies:** T1 and T2 passed; user approves the cutover window.

**Reference files:** `install.sh`, `relay/tailscale-setup.sh`, `internal/setuphelper/tailscale_release.go`, `tests/test_tailscale_bootstrap.sh`, `tests/test_tailscale_consent.sh`.

**Approach:**
- Use the published version with the documented stage-only/private-required installer path. Verify expected repository/version/SHA and `tailscale_setup=1`. Preserve the old release and confirm staging changed neither `current`, service, environment, enrolled identities nor Serve.
- Invoke the candidate's own explicit runbook-adoption helper with its staged release directory and pairing disabled. First reject the approval prompt; verify no activation/service/route/credential changes. Private coordination files are not evidence of service activation.
- Recheck baseline identity, take the final consistent snapshot, then repeat and let the user approve the exact summary. Preserve the existing app origin and endpoint. A matching adopted route should not require a new Serve write or blanket sudo.
- Verify managed state is `verified`, the new exact executable is running under the intended unit, readiness identifies the candidate, listeners remain loopback, gateway is disabled and unrelated routes are unchanged. Check app metadata over the real selected HTTPS endpoint.

**Scenarios / gate:** cancellation is harmless; unknown/drifted runbook is refused; normal adoption retains identity and route. If adoption fails, verify its guarded rollback actually restored the old executable/unit and phone access. For an interrupted incomplete transaction, use the candidate's documented setup recovery path and retained evidence—never manually bypass checks.

**Critical recovery distinction:** `--recover` accepts incomplete setup phases, not a successfully `verified` adoption. If health passes but the phone later fails, stop progression and use T1's separately reviewed reverse-cutover procedure; do not promise that `--recover` will undo a successful adoption. Do not enroll or revoke devices before the original phone has passed T4.

### [ ] T4 — Prove retained phone access and align the registered plugin

**Requirements:** R1, R4–R5. **Dependencies:** T3 passed.

**Reference files:** `relay/plugin-build.sh`, `relay/plugin-status.sh`, `relay/plugin-quick-start.sh`, `relay/plugin-setup-link.sh`, `internal/update/worker.go`, `tests/test_plugin_build.sh`, `tests/blackbox/tailscale_test.go`.

**Scenarios:**
1. Open the existing installed app at its unchanged origin, without scanning another QR or clearing browser data. Confirm authenticated access to the correct computer and a harmless command in the dedicated test tab; avoid controlling actual working agents.
2. Distinguish cached app code from relay code. Load the app update through the normal UI if offered, then confirm expected frontend metadata and retained authentication. A healthy server plus an old cached UI is not complete frontend acceptance.
3. Restart only the managed relay; close/reopen the installed phone app. Existing credentials reconnect without a new invitation. A status page alone is not proof of phone authentication.
4. Only after adoption succeeds, update the registered plugin from this fork pinned to the tested tag or SHA, with automatic setup disabled. The installed CLI supports `--ref`; do not install unpinned fork `main`, which may still contain the old implementation. Review any source-replacement prompt. If Herdr refuses the same plugin ID/source transition, stop and investigate—do not uninstall to force it.
5. Confirm plugin source/ref/version and expected actions. Check private status and the non-pairing service path; the same-release plugin build should avoid unnecessary restart. Explicit pairing actions are deferred to T5.

**Gate:** existing phone authentication/control and frontend refresh pass; plugin actions route to the tested private helpers; semantic relay identity and enrolled device credentials are retained. Device-store timestamps/counters may legitimately change on authentication, so raw whole-file hash equality is not the credential-preservation criterion.

### [ ] T5 — New invitation, normal operation and safe outages

**Requirements:** R4–R5, R7–R8. **Dependencies:** T4 passed; user available for phone actions.

**Reference/test files:** `relay/tailscale-pair.sh`, `internal/setuphelper/tailscale_pairing.go`, `internal/deviceauth/private_test.go`, `frontend/tests/browser/mobile-journeys.spec.ts`.

**Scenarios:**
- Open a separate private pairing terminal only when requested. The agent does not read its output, scrollback, QR, fragment or screenshot. The user scans it into a spare device/profile that does not overwrite the primary installation; record only success/failure. If no separate supported client exists, defer new-enrollment tests rather than destroying the retained pairing evidence.
- Confirm the newly enrolled client authenticates and controls the disposable test tab. A consumed invitation is rejected; a separately generated unused invitation older than ten minutes is rejected. Explicit rearm admits another test enrollment without revoking the original phone.
- Verify restart/reopen does not arm a new invitation. Use secret-suppressing state predicates locally, never a raw device-store dump.
- Disable Tailscale on the **phone only**; it must lose relay access without gateway/public fallback. Restore phone connectivity and confirm credential reconnect. Do not take down this computer's Tailscale or change ACLs for this test.
- Briefly stop/restart the verified relay with approval. Confirm clear offline status and automatic reconnect after restoration. Since app and relay share this host initially, report this as a coupled app/relay outage, not independent app-host-failure proof. Cached UI may still open; that does not imply authenticated connectivity.
- Check the existing endpoint is reachable over real tailnet HTTPS, not a public alternative. Do not enable Funnel or alter policy merely to create a negative test.

**Gate:** tested cases have actual phone observations; original pairing still works. Revoke only specifically identified disposable test devices with approval, not all devices. Retain production credentials and app storage.

### [ ] T6 — Exercise a real managed private update

**Requirements:** R1–R5, R8. **Dependencies:** T4–T5 passed; separately approved second prerelease and maintenance window.

**Reference/test files:** `relay/tailscale-update.sh`, `internal/update/worker.go`, `internal/update/private_test.go`, `tests/test_tailscale_update.sh`, `docs/updates.md`.

**Approach / scenarios:**
- Publish a second immutable, verified private-capable prerelease using T2's gates; even a version-only candidate must contain consistent version metadata. Reusing the first candidate is explicitly only a no-op test.
- Use the normal explicit-version private update path, pin expected revision, verify real cutover, candidate readiness, service enablement, app origin, retained phone authentication and unchanged adopted/unrelated routes. Keep plugin source/ref aligned with the tested update after verifying the cutover.
- Repeat the same version and confirm no unnecessary activation/restart. Observe meaningful readiness and selected-tab control, not merely a successful command exit.
- Run controlled service/HTTPS failures and interruption/rollback experiments only on a disposable installation. Do not SIGKILL a production transaction or delete its evidence to manufacture coverage. Managed update/app-origin interruptions need owner reconciliation; their evidence is not setup `--recover` input.

**Prerelease boundary:** stable update discovery intentionally skips prereleases. The phone's ordinary update checker is expected not to offer these candidates. Explicit-version managed-update success is not proof of stable-channel discovery or phone-initiated stable update. Keep that acceptance outstanding until separately authorized stable publication; do not promote just to make the test appear complete.

### [ ] T7 — Boot behavior and disposable/environment-dependent coverage

**Requirements:** R3–R6, R7. **Dependencies:** stable T4–T6 state; separate approval for each disruptive action/resource.

**Reference/test files:** `docs/tailscale-linux.md`, `tests/test_tailscale_setup.sh`, `tests/test_tailscale_bootstrap.sh`, `tests/test_tailscale_update.sh`, `tests/test_tailscale_defaults.sh`.

| Test | Safe location and success criterion |
| --- | --- |
| Logout/login and reboot | This host only at a user-chosen window after recording recovery/checkpoints. Do not turn on linger implicitly. Verify actual configured session-start behavior and an available Herdr session; do not promise boot-before-login service availability. Reboot may end this agent session. |
| Fresh setup, missing/logged-out Tailscale, conflicts, noninteractive refusal | Disposable Linux VM or separately approved real test user/session with isolated standard paths, genuine systemd user bus and a disposable Herdr session. A fake HOME attached to the production user's bus is not isolation. User performs any Tailscale enrollment. |
| Created vs adopted route teardown, failed cutover, SIGKILL recovery | Disposable installation with distinct identity and unused endpoint. Remove only verified test-created resources; keep adopted routes. Never use production uninstall, device-store deletion or global Serve reset. |
| Shared app A with independent relay B; app A fails while B stays up | Requires a second independently reachable, authorized Linux host/node. One host or two mocked ports cannot prove real two-host availability. Keep existing app origin; prove independent credentials and harmless actions on A/B. |
| iPhone and Android; Ubuntu and Arch/Omarchy; arm64; macOS alternatives | Run only on available real platforms. Local amd64 acceptance and cross-builds do not imply these native gates passed. |
| Stable phone-driven update | Deferred under prerelease-only scope, as specified in T6. |

**Gate:** report each row as PASS, FAIL, BLOCKED or NOT RUN with an explicit reason. Unavailable resources do not block a narrowly labeled minibox acceptance, but do block claiming universal/full release acceptance.

### [ ] T8 — Evidence, cleanup and leave-in-service decision

**Requirements:** all. **Dependencies:** preceding results recorded, with deferred cases explicit.

Create a sanitized operational report (proposed `docs/tailscale-live-acceptance.md`) containing exact candidate SHAs/versions, release/CI URLs, host/platform description, test matrix, downtime observations, original-phone results, rollback results/limits and remaining gates. Keep credentials, private runtime paths, device records, backups and raw logs out of Git and PR uploads. Execution commands and private artifact locations belong in a local owner-only record, not the public report.

Before closing:
- Confirm original phone, selected app origin, verified private service, adopted route and unrelated resources are correct.
- Ask whether to leave the tested candidate running or perform the reviewed backout. Do not silently choose a new production baseline.
- Keep the old bundle and backups until the user approves retention cleanup. Close only test terminals/resources created for this work; never close the user's old pairing pane or unrelated sessions.
- Report **host acceptance passed with listed gaps**, or **blocked/failed**. Do not claim the release is stable, merge PR #1, promote a prerelease, or silently tick previously unrun human gates.

## Permission and terminal contract

| Boundary | Agent responsibility | User responsibility |
| --- | --- | --- |
| Read-only baseline and candidate verification | Show what will be inspected; suppress secrets and unrelated inventory | Approve execution start; confirm current phone behavior |
| Prerelease publication / Actions configuration | Present exact fork/tag/SHA, intended files and workflow/settings changes | Explicit approval for publication/settings; any account authentication |
| Adoption / plugin source change / update | Present scope, downtime, retained backup and recovery route | Approve the visible change summary |
| Privileged Serve or test-user/VM operations | Propose the exact narrow operation; no broad operator grant or policy reset | Type sudo password directly and approve the specific command |
| Pairing | Prepare an unread private terminal and report only non-secret results | Scan QR; do not paste the link or password into chat |
| Logout / reboot / leave candidate running | Persist checkpoint and explain expected behavior | Choose time and final operating state |

One approval covers a bounded phase, not every harmless read command. Re-open approval only when scope, privileges or risk changes. The assistant never types the user's password, enables a public fallback, or treats a terminal timeout as proof that an operation did not happen.

## Risks and stop conditions

- Existing pairing fails after adoption: no re-pair workaround; stop, preserve evidence and use reviewed backout.
- Release or unit identity mismatches, foreign state, unexpected route changes, pending recovery evidence or missing backup: no next mutation.
- Successful setup followed by functional failure: setup `--recover` is not available for the verified phase; the approved reverse-cutover procedure is required.
- Replaying an old device backup can resurrect revoked devices or discard new enrollments. Freeze security changes around the rollback checkpoint and reconcile later device state explicitly.
- The first host serves both UI and relay. Preserve browser storage and distinguish stale cached assets from server or authentication failures.
- A second release, second real node and additional devices/platforms cost time/resources. They are explicit prerequisites, not hidden assumptions.

## Research and review

Grounding: the files listed in each unit, `docs/tailscale-acceptance.md`, the unchanged `docs/plans/2026-09-25-001-feat-tailscale-first-linux-plan.md`, PR #1, read-only installed plugin/release metadata and installed Herdr CLI help. Existing local procedures cover this exact migration; no external web research or delegation was needed.

Direct coherence/feasibility/security review identified and incorporated four important constraints: successful adoption cannot use incomplete-setup recovery; plugin source must be pinned and replaced only after adoption; prereleases are skipped by stable update discovery; a real update requires a second candidate. Review is direct, not independent.

Planning completed without deployment, test execution, service/route mutation, tab creation, secret capture, publication or changes to the original implementation plan. Execution starts at T1 only after approval.
