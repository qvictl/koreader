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
  order on disk. With the final fix, all 19 checks pass, including no second write
  without edits, clearing successful dirty markers, and reopening and painting
  favorites after reloading the persisted settings. It then connects a real
  private folder, flushes while the folder menu remains open and closes it; the
  parent list must refresh its count and folder marker. The intermediate candidate
  fails this case (2 displayed instead of the folder marker plus 3). Related startup
  and generic suspend/resume scenarios each pass 7/7 (33/33 checks across three scenarios).
- Scenario cleanup restores in-memory collections, the read timestamp and exact
  current/backup settings bytes, and removes its private EPUBs. It closes leftover
  widgets and waits for cover metadata workers before deleting their input files.
  A local error-injection variant verifies the same cleanup after an exception;
  that deliberately failed run is not counted as a passed integration scenario.
  An additional body-error plus worker-timeout injection confirms settings/global
  restoration still runs when worker cleanup fails, inputs remain for a possibly
  active worker, and both original and cleanup errors remain visible.
- The native libraries are reused from the authorized fork emulator; runtime
  Lua is overlaid from the tested source. This is not a native rebuild or a
  PocketBook hardware/power-loss durability test. The reproduction establishes
  the missing settings-flush persistence path, not how a particular firmware
  might terminate KOReader.

Exact-head CI, coverage, AI review and unresolved-thread gates remain required
before merging. No upstream writes or device installation are involved.

## Synchronous flush tradeoff and measured limits

`UIManager:flushSettings()` is a synchronous broadcast, not an asynchronous
completion protocol. PocketBook's `EVT_HIDE` / `EVT_BACKGROUND` handler immediately
returns the suspend notification after the broadcast. This fix deliberately
finishes collection persistence before that existing return boundary, matching
other settings handlers. Scheduling a future write or simply forking without a
platform completion barrier could return with the edits still only in memory,
reintroducing the original failure. Waiting for a child at that boundary would
still delay the event loop; it is not an asynchronous responsiveness fix.

This does **not** make serialization or storage latency harmless. Three fresh
Linux x86-64 emulator processes per fixture exercised the actual collection
manager handler, `ReadCollection:write`, full LuaSettings serialization and the
ordinary `.old` backup path. Each fixture used synthetic long book paths, checked
all entries before the timed flush, and reopened the output with the expected
count afterwards. These are host measurements, **not equivalent Kindle hardware
or flash-storage acceptance tests**:

| Collection entries | Settings bytes | Flush duration | Repeat flush without edits |
| ---: | ---: | ---: | ---: |
| 1,000 | 164,963 | 5.4–6.1 ms | ≤0.001 ms |
| 10,000 | 1,667,966 | 151–166 ms | ≤0.002 ms |
| 30,000 | 5,047,966 | 1,150–1,343 ms | ≤0.003 ms |

At 30,000 entries, Lua heap measured before/after the flush rises from about
15,000 KiB to 52,400 KiB, and current RSS (`VmRSS`) rises from 35,496–37,792 KiB to
63,352–65,028 KiB. Process `VmHWM` was already 68,808–69,076 KiB after fixture
construction; that high-water value must not be mislabelled as this flush's
isolated peak. There is a real synchronous pause and memory cost, and slower
Kindle storage can be worse. No device-wide safe latency or memory guarantee is
claimed. Successful dirty-marker clearing removes redundant repeats; it does
not eliminate the cost of the first changed flush or a necessary failed retry.
A broader asynchronous persistence design needs platform lifecycle completion
coordination and state-versioning for concurrent edits before it can safely
replace this synchronous contract.
