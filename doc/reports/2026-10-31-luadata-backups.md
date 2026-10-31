# LuaData backup recency and recoverable history

Investigated while reading the dictionary-history failure report
[upstream 14695](https://github.com/koreader/koreader/issues/14695). That report
includes an unexpectedly ancient `.old.1` backup. The original sparse-history
crash and underlying filesystem corruption are **not** claimed fixed here.

`LuaData:flush` logged that it rotated `.old.i` but actually renamed the current
main file to `.old.(i+1)`. Once `.old.1` existed it remained stale, newer state
replaced `.old.2`, and recovery selected the stale `.old.1` first. This is an
independently reproducible recovery rollback, not a theory about device storage.

A native four-snapshot reproduction (`first`, `second`, `third`, `fourth`) on
the unchanged implementation produces `.old.1=first`, `.old.2=third`, no third
backup, and recovers `first` after corruption of the current file. The correction
rotates the actual backup paths from oldest to newest, within `max_backups`, then
moves the current file to `.old.1`. Missing intermediate files do not stop
rotation of surviving older backups.

## Verification

- Native `luadata_spec.lua`: the initial 14/14 cases pass. The unchanged production module
  fails 6/14, including chronology, newest-valid recovery, corrupt first backup,
  configured retention limit, and a missing intermediate backup.
- One pre-existing assertion expected the stale original snapshot after
  corruption; it now explicitly expects the newest valid backup. The new
  generation tests independently establish the required ordering.
- The initial real emulator scenario `37_dictionary_history_backup` passes 5/5 checks.
  It seeds four synthetic history snapshots, corrupts only its private current
  file before ReaderDictionary initialization, opens the actual history menu,
  and checks the painted widget shows `generation-3`. Unchanged production
  instead shows `generation-1` and fails the scenario.

## Review-driven failure and append regressions

Two independently confirmed review findings are fixed before delivery:

- A failed backup rename must stop rotation before a later rename overwrites the
  still-unmoved source. Both old-backup and current-file rename failures now log
  their error and return `false`; `reset` propagates failure without discarding
  its in-memory data. Opening a new snapshot unsuccessfully also reports failure.
- After recovery removes an invalid current file, an append must persist the
  complete recovered state, not just the new incremental entry. Otherwise the
  next reopen loses earlier lookups and can produce a sparse history table.
  Missing/non-file current paths now take the complete-snapshot flush path.

Initial review-fix native unit validation is 19/19. The pre-review candidate fails all five
new tests: blocked backup rename, blocked current-file rename, snapshot-open
failure, recovered-history append, and recovered-setting save/delete. These use
real temporary directories and files, not simulated rename results. Final
scenario 37 passes 8/8: it additionally performs a real dictionary lookup after
recovery and reopens the on-disk history, verifying both the recovered entry and
the new lookup. The pre-review candidate fails this retained-entry check.

## Recovery-write performance limitation

The first append when the current file is missing persists the complete current
in-memory state synchronously. After that snapshot is successfully written and
the current path is a regular file, later appends are incremental again. A failed
write that leaves the path missing/non-file causes later appends to retry the
complete snapshot, potentially repeating synchronous I/O and UI pauses. This branch
does **not** rotate backups: `flush` rotates only when the current file is a
regular file. It is nevertheless not a bounded/nonblocking I/O implementation.

Three fresh-process Linux x86-64 samples per synthetic history size measured
the first recovered append with `socket.gettime()` and `/proc/self/status`.
Current RSS uses `VmRSS`; the high-water column uses `VmHWM`, not `VmRSS`:

| Entries | Backup / new snapshot bytes | First append wall time | `VmHWM` after append |
| --- | --- | --- | --- |
| 1,000 | 105,923 / 189,021 | 2.1–4.2 ms | 3,476–3,520 KiB |
| 10,000 | 1,068,923 / 1,908,023 | 24.8–37.7 ms | 14,760–15,220 KiB |
| 30,000 | 3,228,923 / 5,768,023 | 84.9–122.8 ms | 34,836–36,020 KiB |

Each record has a synthetic book title (including non-ASCII text), timestamp
and lookup word. For 30,000 entries, pre-append RSS was 14,380–14,432 KiB and
Lua heap grew from 6,677 KiB to 32,653–34,279 KiB before a subsequent collection.
These fast-host results demonstrate real transient allocation and synchronous
latency; they are **not** a Kindle latency or memory-safety guarantee. A 100,000
entry fixture exceeded the LuaJIT loader's constant limit and was rejected;
its timings are invalid and excluded rather than counted as a performance pass.

A local, unpublished 8 KiB backup-copy-plus-delta prototype reduced the need to
serialize the current table, but failed two data-integrity negative controls:
it lost an earlier in-memory append after a blocked write and retry, and used
different data when the numbered backup changed after recovery. Retaining the
complete current in-memory snapshot passes both cases. They are now permanent
unit regressions, bringing the focused suite to 21/21. The prototype is not
part of this change.

An asynchronous or streaming serializer would need separate writer ordering,
current-state ownership, failure/retry and exit-lifecycle design. This repair
deliberately retains immediate persistence semantics rather than accepting
those demonstrated data-loss regressions. Large-history UI pauses remain a
known limitation, not a claim that synchronous serialization is free.

Validation reuses fork emulator native libraries with candidate runtime Lua and
a temporary SDL3 dependency. It is not a native rebuild, Kindle/PocketBook
hardware test, or proof of power-loss durability. All history data is synthetic
and isolated to temporary profiles. CI and exact-head review remain the normal
delivery gates. No existing user backups are migrated, removed, or rewritten by
a new migration; the correction applies when the usual flush operation occurs.
