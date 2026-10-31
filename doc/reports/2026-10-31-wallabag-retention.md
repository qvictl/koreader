# Wallabag status upload: preserve local articles and annotations

Source report: [upstream issue 15471](https://github.com/koreader/koreader/issues/15471).
The report describes completed articles and their sidecars being deleted even when
“Delete remotely archived and deleted articles locally” is disabled. The current
fork has the same unconditional local-cleanup branch in `uploadStatuses`.

This fix requires `sync_remote_archive` before deleting or moving a local article
after a successful remote status upload. The archive-folder preference does not
independently authorize removal. A local inventory entry is removed only after
its local delete/move succeeds, not merely because the remote status changed.
Remote failures retain the local article, and explicit local-removal opt-in keeps
its existing delete/archive behavior.

## Regressions

- `spec/unit/wallabag_spec.lua`: nine cases cover disabled/missing local-removal
  preferences, both archive modes, explicit opt-in, local failure, remote failure,
  and unfinished articles.
- `36_wallabag_local_retention`: real FileManager Wallabag plugin, a private copy
  of the synthetic EPUB, and real annotation sidecar. Manual status upload and
  automatic upload during download must preserve both files byte-for-byte;
  selecting the archive preference alone must not move either file; explicit
  local-removal opt-in must move the EPUB and its annotations together. Only the
  remote API is simulated; no account, user article, or external service is used.

The native Busted suite passes all 9 cases; the unchanged baseline fails 5 of 9.
The real emulator scenario passes 25/25 checks, while the unchanged baseline
fails because manual status upload reports a local deletion despite removal
being disabled. An earlier dependency-stubbed host harness independently gives
the same 5 baseline failures and 9 fixed passes.

These are local Linux-host results using the existing fork emulator native
runtime, current candidate runtime Lua, and a temporary SDL3 dependency. Native
libraries were reused, not rebuilt, and this is not Kindle hardware or a live
Wallabag service test. The initial missing-SDL3 setup failure and an initial
scenario reporting error (binary EPUB values in JSON diagnostics) were corrected;
neither failed invocation counts as a pass. Exact-head CI and review remain
separate delivery gates.

No upstream writes, version changes, release, or reader installation are involved.
