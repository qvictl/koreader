# Cover-menu extraction after closure

This follow-on was discovered while validating collection-flush scenario cleanup.
The collection fix did not change cover-browser production code. On the fork's
current main, `CoverMenu:updateItems()` queues an anonymous next-tick callback to
start metadata extraction. `onCloseWidget()` terminates existing workers and
removes update polling, but it cannot terminate a worker that has not started.
The queued callback then starts a new extraction after the menu has closed.

## Narrow lifecycle fix

The callback checks the existing per-menu `_covermenu_onclose_done` flag before
starting extraction. No worker implementation, scheduling interval, document
cache or cancellation policy changes. Open menus still launch normally, and
closing after launch retains existing worker termination. A closed menu cannot
show a late failed-fork dialog either. The close flag was already used to make
duplicate close notifications harmless; this change does not introduce a new
lifecycle flag or alter its lifetime.

## Evidence

- Six native unit regressions: the unchanged source passes three and fails three
  (late extraction, late failure dialog, repeated close before launch). The guard
  passes all six, including open-menu success/failure and close-after-launch.
  Existing UIManager and BookList suites also pass 20/20 and 19/19, respectively
  (45/45 total in isolated per-suite processes).
- Scenario `46_covermenu_closed_launch` uses actual Favorites cover menus and
  the real UI task queue. It opens and closes an uncached menu in the same UI
  action twice, then leaves a new menu open and verifies a real native child
  extracts the synthetic EPUB's metadata and title. The transport is not mocked:
  its extraction wrapper records calls and delegates to the real implementation.
  The final scenario passes three independent runs, 11/11 checks each.
- The original production code fails the actual scenario's first assertion:
  expected zero launches after closure, observed one. Its worker is terminated
  and reaped during cleanup while the private input still exists. This negative
  is an intentional failed test, not a passed scenario.
- Cleanup drains queued work before termination, waits for the normal reaper,
  restores the collection state and extraction method, and only purges private
  inputs after worker completion is established. It retains inputs if waiting
  fails. The normal reaper interval accounts for most of the host scenario time.

This is a reproducible lifecycle/late-worker bug, not evidence of a measured
Kindle battery regression. A child crash when test code prematurely deleted its
input originally exposed the race; deleting live inputs is not needed to prove
the production bug. Native libraries are from the owner-authorized Linux emulator,
with matching source Lua overlaid. No new native build or Kindle hardware test is
claimed. Exact-head CI, coverage and normal review gates remain required.
