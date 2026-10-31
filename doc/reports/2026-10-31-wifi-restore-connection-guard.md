# Async Wi-Fi restore: share the connection guard

## Upstream evidence and scope

[Upstream #15973](https://github.com/koreader/koreader/issues/15973)
identifies a missing acquire half of the existing connection guard. At fork main
`da47c289`, startup and resume call `restoreWifiAsync()` and start connectivity
polling without setting `pending_connection`. An interactive request or another
resume can therefore start another backend request while restoration is pending
within an awake lifecycle.
The poll already releases the flag on success or timeout.

The upstream report describes one Kobo field observation with user patches and an
external plugin. It explicitly does **not** prove that overlapping requests caused
the reported device hang. This change fixes the independently reproduced source
and UI-level overlap, not a proven physical-device freeze or the separate restore
intent issue #15728.

## Narrow change and contracts

`NetworkMgr:requestToRestoreWifi()` acquires the existing connection guard before
calling the platform backend. Both startup and resume use that wrapper.

- An existing connection owner returns the existing `EBUSY` status without another
  backend request, poll, deadline reset, callback cancellation or success event.
- Accepted `nil` and `true` backend results retain the guard and start the existing
  connectivity poll once. No new `NetworkConnecting` event contract is introduced.
- Explicit `false` or a backend exception releases only the newly acquired guard.
  Exceptions are logged. Failure does not call `_abortWifiConnection()`, discard
  `lease_ssid`, clear in-memory/persisted `wifi_was_on`, or disable the radio. This
  preserves the failure semantics fixed in fork #73 and permits a later retry.
- Existing poll success, poll timeout and explicit disable release ownership.
  Timeout still invokes the existing abort behavior; this is not a fix for #15728.
- `pending_connectivity_check` is not used as an ownership lock: a passive wait can
  exist without a connection request. Existing shared passive-poll behavior is not
  redesigned. Cached connectivity is not a reason to skip a resume restore.

This is single-event-loop ownership within one awake lifecycle, not an
operating-system lock or a transaction across suspend or external plugins/processes. The current platform restore implementations do
not yield through UI callbacks; the guard is set before invoking them.

## Tests and isolation

`spec/unit/network_restore_guard_spec.lua` has 18 cases using the actual manager
and listener with a synthetic platform backend. They cover startup, duplicate
resume, overlap in both directions, accepted `nil`/`true`, explicit failure and
exception retry, preserved restore intent/lease, passive polling/stale cached state,
and release on success, timeout, disable, managed/host-managed radio-off
suspend/resume, the unchanged managed radio-on shutdown path (including failure),
and scan-menu completion. A separate flow test covers blocking takeover. Device capabilities, UI methods,
module-cache entries and settings are restored. Host shell execution is forbidden.

`52_wifi_restore_connection_guard` uses a real TouchMenu, tap input, busy
InfoMessage, UIManager task queue and 0.25-second connectivity polls. Only radio
state/backend calls and device capabilities are synthetic. It checks duplicate
resume leaves one request and the original poll, user input cannot start a second
request, dismissing the busy message returns to a usable menu, normal completion
and shutdown events, explicit failure followed by successful retry, and interrupted
suspend followed by fresh restoration. Cleanup
cancels the owned poll and restores global boundaries even if widget cleanup fails.
No host Wi-Fi script, physical radio or external-network request is exercised.

## Validation

Initial production/test commit `952bfe0da86164ea8426079ba686763d04c219ab`
(tree `d53793b177a242a68bb299232d17c8fcc11ecd5a`) was based on main
`da47c289`: 151 focused unit cases and 70 integration checks passed.

The initial main combination `e93cac6884ae21d751faac5feb75720a5ae02135`
(tree `cf3855c54a6f3adaf39eda691d9b3022f75532d4`) merges actual accepted
main `624275dc` from fork #77. The only merge conflict was adjacent README rows;
both 51 and 52 are preserved. The candidate's production/test bytes are unchanged.
That combination passed 176 focused unit cases and 92 integration checks.
CodeRabbit subsequently identified the interrupted-restore lifecycle gap below;
those earlier numbers do not establish the corrected suspend behavior.

### First review: suspend interruption fix (historical, superseded below)

CodeRabbit correctly found that suspending before the radio reported on left the
new restore guard alive. A subsequent resume could return `EBUSY` instead of
requesting restoration. The original review head fails the extended real-UI
scenario at `suspend retires the interrupted restore ownership`.

Corrected production/test commit `2a42b764230ef2bd795ffc0608b0660ae81886ff`
(tree `25f78081b716615560ee2354a1c16fa94c0ca8de`) adds `pending_restore` to
identify the subset of pending connections owned by restoration. Busy callers do
not change that ownership. Failure/exception, poll success/timeout, explicit
disable, blocking `goOnlineToRun()` takeover, and scan-menu completion all release
it alongside `pending_connection`.

This earlier revision used a broader managed-device suspend condition: suspending
an unfinished restore on Kobo/Cervantes/Bookeen used
the existing disable path even before the radio reports on. The synthetic tests
observe the existing script-stop command and shutdown request, with accepted
`nil`/`true` and failed `false` results. This is **not** physical confirmation that
a shell child has terminated. Failed shutdown retains the existing lease/intent
contract and does not emit a successful disconnect.

Kindle's restore submits a synchronous LIPC enable request; the host system manages
suspend. Its suspend branch retires the Lua poll/restore flags without issuing a
new radio shutdown, changing lease/intent or scheduling a delayed disconnect.
This avoids introducing the existing Kindle shutdown callback's two-second delay
across a new connection. Unrelated host-managed interactive ownership is left
unchanged. Poll cancellation retains the existing function-wide behavior; this is
not a per-request token redesign of shared passive polling.

The extended scenario interrupts restore with Suspend/Resume, verifies a fresh
request and poll, and checks no stale disconnect or lease loss after 2.1 seconds.
The central synthetic assertion is **zero host-managed shutdown requests**; the
mock shutdown is synchronous, not an independent emulation of Kindle's delayed
callback. The combined scenario 47 still exercises the actual Kindle helper's
synthetic LIPC boundary. Neither scenario is physical-device proof.

The following results were rerun against the corrected code/test tree. The
report-only successor does not change executable/test bytes.

| Check | Result |
|---|---|
| New unit suite | 17/17 |
| Fourteen focused unit suites | 184/184; one pre-existing host loopback case explicitly excluded |
| Real emulator scenarios 01 / 09 / 47 / 51 / 52 | 103/103 checks; applicable budgets pass |
| Scenario 52, three fresh-profile repeats | 3 × 38/38 |
| Fresh changed-line unit coverage | 24/24 (100%) across three production files |
| Lua lint / original pixel-size checks / whitespace | Pass; zero Lua warnings/errors; no rule changes |

The focused suites are `network_restore_guard`, `networkmgr_flows`,
`network_manager`, `network_dns_async`, `networksetting`, `kindle_wifi_lipc`,
`kindle_wifi_toggle_failure`, `autosuspend_network`, `dispatcher`, `uimanager`,
`coverlist_narrow`, `covermenu_lifecycle`, `textboxwidget` and `imagewidget`.
The exact excluded existing case is
`ifHasAnAddress finds the loopback address when the interface is up`: this host's
native getifaddrs fixture limitation was already observed before this change.
Its assertion is unchanged and normal CI must still run it. This is a focused pass,
not a full-suite pass.

Negative controls used unchanged main production with the synthetic boundaries:
startup allowed an extra interactive backend request, and duplicate resume invoked
the restore backend twice instead of once. The final real-UI scenario also fails
on unchanged production with `duplicate resume does not restart the backend
(expected 1, got 2)`. An initial scenario diagnostic wrapped a failed assertion as
a table address; moving that assertion outside the UI action restored the precise
diagnostic without changing its condition. No failure was counted as a passing run.

An independent reviewer checked that revision’s source, lifecycle ownership,
cleanup and recorded positive/negative logs, initially finding no remaining blocker.
The later process-lifecycle review below exposed a limitation this review missed. The earlier
review missed the suspend boundary; CodeRabbit’s valid finding was accepted and
fixed rather than dismissed. Independent review was static/log review, not another
runtime execution. New exact-head CI and normal included re-review remain required.

### Second review: remove the new backend shutdown entry; keep a narrower contract

The next included review found two valid boundaries in `2af8fb59`: the new
radio-off/pending condition could enter the synchronous shutdown scripts, and
sending TERM to a restore parent does not guarantee its enable child has stopped.
That head's exact CI passed, but the PR was put back in draft with `do-not-merge`.
Neither synthetic radio tests nor a green build establish backend quiescence.

The narrowed candidate restores the original
`Device:hasWifiManager() and NetworkMgr:isWifiOn()` backend shutdown condition.
If a restore still owns Lua state when that condition is false, suspend only
retires the current awake lifecycle's poll and two flags. It preserves restore
intent and lease, sends no backend-stop/disconnected event, and does not add a
radio shutdown request. Managed radios already on retain the existing shutdown
path, including its failure semantics. Host-managed radios retain their existing
system-managed behavior. Poll completion/timeout and other release paths still
clear both flags. This avoids a new stale-guard `EBUSY` without claiming a shell
process tree has stopped.

**Known deficiency retained:** a restore child can outlive its parent and overlap
a later resume, just as on main `624275dc`. This PR does not fix complete backend
cancellation, bound shutdown latency, guarantee cross-suspend mutual exclusion, or
explain the reported physical Kobo hang. It only guards requests/polls within the
current awake lifecycle. Formal review must assess this scope; the hold is not
cleared merely because the limitation is documented.

#### Baseline comparison and process evidence

Two separate, explicitly limited experiments support the narrower scope:

1. A private harness loads actual main `6444a3ce` manager/listener (unchanged
   from `624275dc`) and the
   narrowed versions with the same synthetic device/queue boundary. Each runs six
   deterministic event sequences. Both radio-off managed/host-managed
   Resume/Suspend/Suspend/Resume traces are `restore, restore`. Managed radio-on
   traces, with shutdown returning nil/true/false, are identically
   `restore, stop, disable, restore`. A duplicate Resume inside the same awake
   lifecycle falls from three total restore calls to two across the suspend
   sequence. All six comparisons pass for each source version. This proves the
   observed backend-call sequences, not kernel scheduling or hardware behavior.
2. A separate Linux process fixture uses the exact unchanged Kobo restore shell
   (SHA-256 `c33382058e63105dd10f3aebb724cae71fbae4514f38a4d812cf4c8c356ebe40`)
   with synthetic enable/association/DHCP commands and FIFO readiness barriers.
   Terminating and reaping only the owned restore parent leaves its enable child
   able to finish. Replaying the measured radio-off traces produces **two live
   restore/enable pairs for both baseline and narrowed candidate**, demonstrating
   the same remaining overlap rather than a cancellation pass. The replay is a
   composition with the Lua trace experiment, not an end-to-end real-device test.

The process fixtures use private sessions, verify process-group ownership before
signalling, reap their owned descendants, and execute no host radio commands or
global `pkill`. They are Linux-host diagnostic evidence, not portable CI tests or
a claim that old reader kernels support the fixture's subreaper facility.

The extended real-UI scenario now includes managed radio-off repeated suspend and
fresh resume. Host shell calls are forbidden, so the previous broader listener
fails precisely when it tries to enter the stop/shutdown path. The ineffective
2.1-second fixed wait was removed: no delayed callback had been scheduled. Its
remaining assertions describe poll completion and lease preservation, not a
simulated Kindle two-second callback.

Validation of the narrowed final source/test tree is recorded separately below;
earlier 184/103 and 3 × 38 figures remain historical evidence, not results for this
revision.

Source/test snapshot `1e673e819859a93d7120709d5f3f1358d8765134`, based on
main `624275dc`, passed 185 focused unit cases across the same fourteen suites
(with the same explicitly disclosed loopback exclusion), 113 checks across
01/09/47/51/52, and 3 × 48/48 fresh scenario-52 runs. Fresh changed-line coverage is
23/23 across three production files. Lua lint is clean; original size checks and
whitespace pass. The old broader `2af8fb59` listener fails the added managed
radio-off test by attempting the forbidden host-shell boundary.

The first combined integration invocation overlapped a diagnostic runtime-file
swap; it is not used as final-tree evidence. The complete five-scenario run was
repeated after the final source files were stable; the 113-check figure above
refers only to that stable repeat.

Reachable source/test commit `64e82eba461edf34a625e69ee58458116417ab8f`
(tree `64afb0c2e4e8ee3d38b1cbbfa3dedc2718ca74ea`) also merges actual accepted
main `6444a3ce` (cover format selection fix). The README retains 51/52/53;
network source/test bytes are unchanged from the preceding snapshot. This final
combination passes **206 focused unit cases** across sixteen suites (the fourteen
above plus `coverimage_format` and `coverimage_bootlogo`), and **155 integration
checks** across 01/09/47/48/51/52/53. Fresh coverage was rerun against main `6444a3ce`: **23/23** changed
executable lines, and another **3 × 48/48** scenario-52 runs passed. Original size
checks and whitespace still pass; no test or lint requirements were weakened.

An independent reviewer checked the narrowed source, scenario cleanup, baseline
source identity, private trace/replay evidence and attributed logs without finding
a new blocker. That was static/log review, not an independent runtime rerun.
Normal exact-head CI/re-review remain separate requirements. The PR stays held
until the limited scope and evidence have been formally accepted; this report
does not resolve review threads.

#### Separate backend-supervision work, not part of this fix

Simply backgrounding shutdown could race suspend: Generic's existing power path
explicitly shuts down Wi-Fi first because Kobo can fail to suspend or deadlock
with the radio on. Kobo release/disable scripts each have a five-second udhcpc
polling loop, plus kernel/other process calls; this is not a total duration bound.

A process group alone is also insufficient. Existing wpa/DHCP commands request
daemonization, which can leave the worker's group. A complete design must define
foreground child or daemon identity ownership, startup readiness, connection
success versus session lifetime, cancellation acknowledgement and bounded failure
handling. It must stop a new restore when cancellation is unconfirmed and prevent
actual suspend submission on that timeout. Returning false from the listener does
not provide a suspend veto: the broadcast result is ignored before scheduling
suspend. These requirements cross platform scripts and power-management entry
points and are not safely implemented by this Lua guard or a generic kill helper.

## Limitations

The Linux emulator runs the authorized existing native runtime with the candidate
Lua source/tests and the accepted base proxy module. It is not a freshly rebuilt
native library set or a physical Kobo/Kindle/macOS execution. No claim is made
about all causes of firmware/network hangs or whole-repository/release coverage.
