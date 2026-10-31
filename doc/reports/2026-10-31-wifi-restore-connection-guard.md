# Async Wi-Fi restore: share the connection guard

## Upstream evidence and scope

[Upstream #15973](https://github.com/koreader/koreader/issues/15973)
identifies a missing acquire half of the existing connection guard. At fork main
`da47c289`, startup and resume call `restoreWifiAsync()` and start connectivity
polling without setting `pending_connection`. An interactive request or another
resume can therefore start another backend request while restoration is pending.
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

This is single-event-loop ownership, not an operating-system lock or a transaction
across external plugins/processes. The current platform restore implementations do
not yield through UI callbacks; the guard is set before invoking them.

## Tests and isolation

`spec/unit/network_restore_guard_spec.lua` has 10 cases using the actual manager
and listener with a synthetic platform backend. They cover startup, duplicate
resume, overlap in both directions, accepted `nil`/`true`, explicit failure and
exception retry, preserved restore intent/lease, passive polling/stale cached state,
and release on success, timeout and disable. Device capabilities, UI methods,
module-cache entries and settings are restored. Host shell execution is forbidden.

`52_wifi_restore_connection_guard` uses a real TouchMenu, tap input, busy
InfoMessage, UIManager task queue and 0.25-second connectivity polls. Only radio
state/backend calls and device capabilities are synthetic. It checks duplicate
resume leaves one request and the original poll, user input cannot start a second
request, dismissing the busy message returns to a usable menu, normal completion
and shutdown events, and explicit failure followed by successful retry. Cleanup
cancels the owned poll and restores global boundaries even if widget cleanup fails.
No host Wi-Fi script, physical radio or external-network request is exercised.

## Validation

Production/test commit `952bfe0da86164ea8426079ba686763d04c219ab`, tree
`d53793b177a242a68bb299232d17c8fcc11ecd5a`, is based on accepted main
`da47c289`. The report-only successor does not change executable/test bytes.

| Check | Result |
|---|---|
| New unit suite | 10/10 |
| Ten focused unit suites | 151/151; one pre-existing host loopback case explicitly excluded |
| Real emulator scenarios 01 / 09 / 47 / 52 | 70/70 checks; applicable budgets pass |
| Scenario 52, three fresh-profile repeats | 3 × 27/27 |
| Fresh changed-line unit coverage | 12/12 (100%) across the two production files |
| Lua lint / original pixel-size checks / whitespace | Pass; zero Lua warnings/errors; no rule changes |

The focused suites are `network_restore_guard`, `networkmgr_flows`,
`network_manager`, `network_dns_async`, `networksetting`, `kindle_wifi_lipc`,
`kindle_wifi_toggle_failure`, `autosuspend_network`, `dispatcher` and `uimanager`.
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

An independent reviewer checked source, cleanup and recorded positive/negative
logs, finding no remaining blocker. That was static/log review, not independent
runtime execution. Exact-head CI and normal included review remain required.

## Limitations

The Linux emulator runs the authorized existing native runtime with the candidate
Lua source/tests and the accepted base proxy module. It is not a freshly rebuilt
native library set or a physical Kobo/Kindle/macOS execution. No claim is made
about all causes of firmware/network hangs or whole-repository/release coverage.
