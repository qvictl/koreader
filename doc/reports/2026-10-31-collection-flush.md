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
normal close behavior; unchanged collections still do not trigger a write.
There is no new storage format, full-directory scan, or suspend hook.

## Reproduction and validation

- Native focused unit suite: unchanged production fails 3/5 cases because no
  write is dispatched for a settings flush; the fix passes 5/5, including later
  edits, the all-collections marker, unchanged data and normal close.
- Real emulator scenario `43_collection_settings_flush`: creates two private
  synthetic EPUBs, opens the actual favorites and manual-sort widgets, moves
  the second book before the first and closes favorites. The file manager stays
  open. Before flushing, disk order is intentionally still the original order.
  The baseline then fails because `UIManager:flushSettings()` leaves that old
  order on disk. With the fix, all 9 checks pass, including reopening and painting
  favorites after reloading the persisted settings.
- The native libraries are reused from the authorized fork emulator; runtime
  Lua is overlaid from the tested source. This is not a native rebuild or a
  PocketBook hardware/power-loss durability test. The reproduction establishes
  the missing settings-flush persistence path, not how a particular firmware
  might terminate KOReader.

Exact-head CI, coverage, AI review and unresolved-thread gates remain required
before merging. No upstream writes or device installation are involved.
