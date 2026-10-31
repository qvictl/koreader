# Collection edits must participate in settings flushes

Investigated [upstream issue 15841](https://github.com/koreader/koreader/issues/15841),
which reports that manually reordered favorites return to their old order after
PocketBook standby, but survive a normal KOReader restart.

The current collection manager marks edited collections in memory and writes
them only from `onCloseWidget`. Closing the favorites menu closes the book list,
not its owning file manager or reader module. PocketBook's `EVT_HIDE` and
`EVT_BACKGROUND` paths call `UIManager:flushSettings()` before the suspend
notification, but the collection manager does not handle that event.

The fix maps `onFlushSettings` to the existing close-time persistence handler.
It keeps the existing changed-collection filter, all-collections marker and
normal close behavior. After a successful write it clears those dirty markers,
so later flushes without edits do not repeat serialization and disk writes.
Failed writes retain the markers and request a full in-memory collection rewrite
on retry: a failed write may have truncated the file, so merging only the last
edits could lose previously persisted collections. The connected-folder menu
compares its parent row with current metadata on close, independently of whether
a settings flush already cleared persistence markers. There is no new storage format,
full-directory scan, or suspend hook.

For that success test to be meaningful, `ReadCollection:write` now propagates
`LuaSettings:flush`'s result. `LuaSettings` keeps returning itself on success but
returns `false, error` on failure. `util.writeToFile` checks Lua file write,
buffer-flush and close results; previously only open failures were reported.
Existing native file/directory fsync remains best-effort for compatibility with
filesystems that do not support it. This is not a new durability guarantee.
The inspected LuaSettings flush call sites ignore the result or use it as the
last expression in a chain; successful return compatibility is tested.

## Reproduction and validation

- Initial focused unit suite: unchanged production fails 3/5 cases because no
  write is dispatched for a settings flush; the initial fix passes 5/5.
  Review-driven failure propagation and dirty-marker tests bring the focused
  suites to 17/17. The pre-review candidate fails all eight additional failure
  and repeat-write cases (seven assertions and one unsupported mock-file error).
- Related native settings, sidecar, persistence and utility validation totals
  132/132 across seven suites, including the focused suites. Utility MD5 fixtures
  match the pinned official `koreader/test-data` blobs. Failure injection checks
  write, buffer flush and close errors; a real missing-parent failure is then
  retried successfully with the original in-memory data intact. Independent review
  identified a later-write retry hazard: after committing collection A, a write
  for B truncates the actual settings file and fails. Without the full-rebuild
  marker, retry loses A; the regression verifies both A and B survive. It also
  checks changed and unchanged parent metadata with persistence markers cleared.
- Real emulator scenario `43_collection_settings_flush`: creates two private
  synthetic EPUBs, opens the actual favorites and manual-sort widgets, moves
  the second book before the first and closes favorites. The file manager stays
  open. Before flushing, disk order is intentionally still the original order.
  The baseline then fails because `UIManager:flushSettings()` leaves that old
  order on disk. With the final fix, all 16 checks pass, including no second write
  without edits, clearing successful dirty markers, and reopening and painting
  favorites after reloading the persisted settings. It then connects a real
  private folder, flushes while the folder menu remains open and closes it; the
  parent list must refresh its count and folder marker. The intermediate candidate
  fails this case (2 displayed instead of the folder marker plus 3). Related startup
  and generic suspend/resume scenarios each pass 7/7 (30/30 checks across three scenarios).
- The native libraries are reused from the authorized fork emulator; runtime
  Lua is overlaid from the tested source. This is not a native rebuild or a
  PocketBook hardware/power-loss durability test. The reproduction establishes
  the missing settings-flush persistence path, not how a particular firmware
  might terminate KOReader.

Exact-head CI, coverage, AI review and unresolved-thread gates remain required
before merging. No upstream writes or device installation are involved.
