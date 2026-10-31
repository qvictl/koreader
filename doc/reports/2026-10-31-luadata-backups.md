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

Final native unit validation is 19/19. The pre-review candidate fails all five
new tests: blocked backup rename, blocked current-file rename, snapshot-open
failure, recovered-history append, and recovered-setting save/delete. These use
real temporary directories and files, not simulated rename results. Final
scenario 37 passes 8/8: it additionally performs a real dictionary lookup after
recovery and reopens the on-disk history, verifying both the recovered entry and
the new lookup. The pre-review candidate fails this retained-entry check.

Validation reuses fork emulator native libraries with candidate runtime Lua and
a temporary SDL3 dependency. It is not a native rebuild, Kindle/PocketBook
hardware test, or proof of power-loss durability. All history data is synthetic
and isolated to temporary profiles. CI and exact-head review remain the normal
delivery gates. No existing user backups are migrated, removed, or rewritten by
a new migration; the correction applies when the usual flush operation occurs.
