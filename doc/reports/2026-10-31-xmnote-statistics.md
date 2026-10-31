# XMNote statistics queries: literal metadata and bounded connection lifetime

Investigated [upstream PR 15964](https://github.com/koreader/koreader/pull/15964)
at `c37858d6c70962d2e9bb01d99b044ebaaf1d4756`. The fork still interpolates a
book's title and checksum into SQL and executes that string through LJSQLite's
semicolon-splitting `exec` helper. This candidate independently implements the
query/lifetime subset; it does not copy the proposed identity or protocol changes.

## Confirmed failures

- Real SQLite rejects an ordinary apostrophe title (`Reader's 日本語`) and a title
  containing a semicolon. The actual exporter next-tick callback then aborts the
  emulator with `near "s": syntax error` when exporting the combined title.
- A synthetic SQL-like title (`' OR 1=1 --`) acquires another fixture book's
  durations even with a different checksum. Metadata must be bound as data, not
  interpreted as SQL.
- A missing title/checksum match returns before closing the connection. The
  native binding retains per-connection registries, so explicit closure matters.
- Query errors (missing statistics tables or a corrupt statistics file) escape
  the optional statistics lookup and abort highlight export.

## Narrow fix and preserved behavior

The lookup binds title/checksum and the selected book ID through prepared
statements. It still uses the existing exact `(title, md5)` match and `LIMIT 1`;
it does not guess by author/title, compute a missing checksum, or change the
reading-status enum or XMNote response-code interpretation. Date grouping,
latest page, duration totals, millisecond timestamp conversion and the existing
empty-table fallback representation are unchanged.

The database opens read-only, preventing a missing-file race from creating a new
empty statistics database. Protected queries always close a successfully opened
connection; the binding's close also finalizes a statement left open by an error.
Open failures are cleaned internally by the binding. Optional statistics failures
log one diagnostic line and yield the existing empty fallback; highlights and
notes can still export. This does not claim lost statistics were recovered or
validate a live XMNote server's protocol.

## Validation

- Native focused suite: 15/15 pass. The initial unchanged source passes 4/13 and fails
  the other nine (five assertion failures and four errors), including actual
  SQLite syntax/identity/lifetime failures, missing-file open and query errors.
- Existing exporter suite: 3/3 pass in its own native process. The official
  `juliet.epub` fixture matches pinned test-data blob
  `a29d2e019c1cbb6ae8b03e3e0532f9fb019413c5`.
- An initial combined two-suite Busted invocation fails when the SQLite module is
  reloaded across suites while FFI metatypes retain old connection registries.
  This is not counted as a pass; suites were rerun in separate processes, as in
  the native test runner's normal per-suite isolation. No binding workaround or
  production change was made to hide that harness limitation.
- Real scenario `45_xmnote_statistics`: 26/26 checks. It uses the actual exporter
  callback and painted success summary, a private EPUB/sidecar and the statistics
  plugin's real schema/view. Literal quoted/Unicode/semicolon titles retain their
  statistics and notes; SQL-like unmatched titles acquire no foreign durations;
  absent reading durations do not suppress highlight text. Only the online gate
  and remote transport are simulated, with no external network or account.
  An injected optional-statistics close exception after real SQLite cleanup also
  preserves the note export and success UI. Related startup passes 7/7.
- Review follow-up protects connection-close exceptions independently of query
  errors. Two new fault-injection unit cases fail against the previous candidate
  and pass after the guard, preserving successful statistics or the empty fallback
  as appropriate. The pinned binding uses `sqlite3_close_v2`; a naturally occurring
  close failure was not reproduced, and these injections are not presented as one.
- The old-source integration negative control crashes in the actual queued export
  callback. A separate intentional body-error plus cleanup-SQL-error injection
  confirms connection closure and transport callback restoration and preserves
  both error messages; this failed probe is not counted as a passed scenario.
- Cleanup restores target settings/callbacks and removes only the synthetic book
  ID and page rows, preserving the initialized database schema. Private EPUBs and
  sidecars are removed on the normal cleanup path; abrupt process failure can
  retain isolated profiles as diagnostic evidence.

Native libraries come from the authorized emulator, with source Lua overlaid.
This is not a native rebuild, live-server test, or Kindle hardware validation.
Exact-head CI, changed-line coverage and normal review gates remain required.
