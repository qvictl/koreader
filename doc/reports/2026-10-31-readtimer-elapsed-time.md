# ReadTimer: elapsed deadlines across standby and view changes

## Evidence and scope

[Upstream #14661](https://github.com/koreader/koreader/issues/14661) reports a
15-minute reading timer retaining several minutes after that interval has passed;
comments mention Android, Kobo and PocketBook. The current fork at `000b434e`
stores and measures the timer deadline with `time.now()`, the UI's monotonic clock.
Its resume handler nevertheless describes the deadline as real elapsed time.

On Linux, MONOTONIC excludes suspended time, while BOOTTIME includes it; REALTIME
also advances but can jump when the clock is adjusted.
[Clock API reference](https://man7.org/linux/man-pages/man2/clock_gettime.2.html).
KOReader already exposes `time.boottime_or_realtime_coarse()` with the latter
fallback on systems lacking BOOTTIME. Android's device implementation also omits
the Resume broadcast when `brokenLifecycle` is set.

This establishes a reproducible code-level clock mismatch, **not a verified
diagnosis of every reported device**. Separate synthetic elapsed/UI clocks leave
the old timer at 900 seconds after advancing elapsed time by eight minutes,
instead of 420 seconds. A real emulator menu/input-hook scenario reproduces the
same difference: about 899.97 seconds instead of 420.

The clock/helper/input approach is adapted from globalhuman's
[upstream PR #15335](https://github.com/koreader/koreader/pull/15335), commit
`84f5044c05c4d8a0ed0bf3792e8c63379d6aabb3`, credited in the commit. This is not a
verbatim cherry-pick: the current expiry event, profile-trigger registration,
Snooze/Repeat UI and fork status-bar behavior are retained.

## Change and lifecycle boundaries

- Store and measure deadlines in the existing suspend-inclusive clock domain.
  UIManager still uses its existing monotonic task queue.
- Reconcile on Resume and through the existing InputEvent hook, including when
  no Resume arrives. Repeated input does not extend the deadline or duplicate
  the alarm task. HookContainer's existing wrapper unregisters each closed view.
- Cancel old alarm/display tasks **before** invoking an overdue callback. The
  former post-callback `unschedule()` canceled newly repeated intervals. Refresh
  stopped timer fields without scheduling a second display loop for a new timer.
- Preserve a timer started synchronously by an expiry profile. If the profile
  closes the view, do not continue using its book information or show a stale
  expiry popup. Closing also removes display tasks after `self.time` is cleared.
- Recheck the elapsed deadline when a queued UI callback runs. If the REALTIME
  fallback moves backward, retain the deadline and requeue the alarm/display
  tasks rather than firing early. Resume uses the expiry helper's result rather
  than a redundant clock read; deterministic rollback-between-checks tests cover
  both callback and resume entry boundaries.

The static deadline transfer between FileManager and ReaderUI stays in the same
process and clock domain. A stopped timer is not transferred. A long sleep emits
one overdue expiry, not a burst for every missed repeat; an automatic repeat
starts a fresh interval from handling time, retaining the existing policy.

This does **not** wake suspended hardware at the alarm deadline. Expiry is
reconciled when execution resumes or input arrives. The REALTIME fallback still
inherits clock-adjustment semantics: a backward correction can extend the
remaining duration, and a forward correction can make it due. No system clock is
changed by the implementation or tests. Broader existing policies for manual
stop during expiry/profile handling or old popup callbacks are not redesigned.

## Validation

Production/test commit `247506fc608a54036db424aec01316d5fd747821`, tree
`9ba2f1289c7678e6b66b144c40c34f355a2af20a`, matches local tested code based on
accepted main `000b434e`. The report-only successor changes no executable/test
bytes. Integration README entries 54 and 55 are both retained.

| Check | Result |
|---|---|
| New unit suite | 21/21 |
| Twenty-one focused unit suites | 211/211, no exclusions |
| Emulator scenarios 01 / 09 / 47 / 48 / 50 / 51 / 53 / 54 / 55 | 215/215 checks; applicable budgets pass |
| Scenario 55, three final fresh-profile repeats | 3 × 30/30 |
| Fresh changed-line unit coverage | 31/31 (100%); not whole-repository coverage |
| Lua lint / original pixel-size checks / whitespace | Pass; zero Lua warnings/errors and no rule changes |

The focused suites are `readtimer`, `time`, `mock_time`, `hook_container`,
`datetime`, `frontlight`, `dispatcher`, `uimanager`, `menu_table_screen_color`,
`readerui`, `readerui_lifecycle`, `readerstatus_lifecycle`, `coverimage_format`,
`coverimage_bootlogo`, `coverlist_narrow`, `covermenu_lifecycle`, `textboxwidget`,
`imagewidget`, `luasettings`, `autowarmth` and `autosuspend`.

Initial unchanged-code controls fail all four core assertions: elapsed remaining
time, overdue Resume, preservation of an automatically repeated timer and
InputEvent expiry. The final unchanged-main control passes 2/21, with 17 assertion
failures and two errors: a closed-view access and the expected absence of the
new `expireIfDue` helper. These are not claimed as 19 independently reproduced
device bugs. Additional prototype controls expose the stale display task and
rollback windows before their focused fixes; the final suite covers them all.

Scenario 55 uses the actual FileManager/ReaderUI plugin instances, menu, interval
picker, Snooze/Repeat buttons, event hooks and UI task queue. Only the timer
class's elapsed-clock method is synthetic; the global/UI clocks and other device
plugins are not shifted. It verifies overdue input, resume auto-repeat, transfer
through both view changes, and native EPUB page turning/close/reopen progress.
It does not wait fifteen minutes or physically suspend a device.

Cleanup discovers both recorded and currently live timer owners after an
interrupted view transition, cancels their tasks, restores the clock before
independent reader/widget cleanup, then restores saved settings/static state.
Private EPUB inputs remain available through background-worker/process teardown.
Unit boundaries, notification stack and settings are restored between cases.
An initial scenario fixture was overwritten by fresh-profile legacy migration;
configuration now happens after startup. That failed harness run is not counted
as passing evidence or a newly discovered product failure.

Independent source/log review found no remaining blocker; it was not an
independent runtime rerun. Exact-head CI and normal included review remain
required. Results use authorized existing Linux-emulator native assets, not a
fresh native/release build or physical Android/Kobo/PocketBook validation.
