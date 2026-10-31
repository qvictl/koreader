# Calibre inbox initialization: contain errors and retire the connection

## Provenance and bounded scope

Upstream [#13956](https://github.com/koreader/koreader/issues/13956) reports a
`rapidjson.dump` open error from `saveBookList → cleanUnused → init → connect`.
The older [#9889](https://github.com/koreader/koreader/issues/9889) contains the
same call chain, and discusses stale inbox configuration and the importance of
distinguishing a local folder problem from a server connection problem. Its
unrelated later Android crash report is not diagnosed here.

Current fork main already prompts when the configured inbox is not a directory.
That does not prove the metadata file can be opened. At actual main
`9b1834c0b8333dc7d9c456b591a0706d72ee8622`, `connect` still starts its message
queue and calls `CalibreMetadata:init` without a local error boundary. Fork #70
isolated metadata ownership between consumers; it explicitly did not address
unwritable inboxes. Current open fork/upstream PR searches found no competing
initialization-error fix. This change does not modify search or collection code.

The initial unchanged-code probe used a newly created private inbox containing
a **directory** named `.metadata.calibre`. Native RapidJSON raised its normal
open error. The connection coroutine failed after one fake transport started;
zero stop/remove calls occurred and `calibre_socket` remained set. No permission
change, symlink, device, remote server or network request was needed.

The real-menu negative test on current main is more precise than the historical
device crash reports: modern `Trapper:wrap` logs the escaped initialization
exception, but the new local-inbox notice never appears and the failed session
is not retired until fixture cleanup. This report does not claim a current
whole-process crash or reproduce the reporters' physical devices.

## Change

Only `plugins/calibre.koplugin/wireless.lua` changes in production:

1. Protect the existing synchronous metadata initialization with `pcall`.
2. Log the original error and inbox path.
3. On exception, call existing `disconnect(true)` **before** a potentially
   yielding error notice. This removes/stops the queue, clears metadata and
   resume state, and applies normal search-cache invalidation without a NOOP.
4. Explain that the local inbox/metadata files need checking, then return.
   Do not fall through to a DNS/TCP diagnostic or mislabel this a handshake error.

Successful setup, handshake waits, network gating, chooser behavior, cancellation,
normal disconnect protocol and duplicate-connect behavior are unchanged.

**Not a transactional save fix:** an exception during a later phase of a write
may already have modified a metadata file. There is no rollback, durability or
atomic replacement guarantee. False/nil return conventions are not changed;
the boundary handles exceptions. Later transfer-time writes, permissions,
filesystem policy, server discovery and native MQ behavior are outside scope.

## Final source/test snapshot and local evidence

Source/test commit: `f3369f67cae45dcc9b43f0326094bd5b70293105`.
Tree: `5dee5b32300ea0b4289ad8980a0a54e5fd6c35f1`.
The following report-only commit does not alter those files. Remote publication
uses an independently verified identical tree; the PR records its exact head.

- `spec/unit/calibre_init_error_spec.lua`: **15/15**. Native open error,
  cleanup before a yielding notice, repeated failure, same/different inbox
  recovery, partially loaded state, non-string exception, valid empty/existing
  metadata, both cancellation waits, duplicate connect, separate transport
  failure, chooser resume and cancelled network gating.
- Six complete scoped unit suites: **102/102** (Calibre initialization,
  metadata isolation, wireless collections, style notifications, Wikipedia
  languages and Wallabag sink lifecycle).
- Repository changed-line unit coverage: **7/7 = 100%**. Whole-repository
  coverage is unmeasured locally; this is not a full/release coverage claim.
- Scenario `65_calibre_inbox_initialization`: **87/87**, three final fresh runs
  (standalone, adjacent combination, and restored-candidate run). Inbox error
  notice budget was 254–258 ms against 5000 ms in those runs.
- Fourteen complete integration scenarios **01/02/03/05/06/12/41/58/59/60/62/63/64/65**:
  **686/686** checks, applicable budgets passed.
- Negative control, exact main90 production with final tests: **7 passed,
  8 failed** units; real-menu scenario timed out waiting for the local error
  notice and logged the native metadata exception. Restored candidate source
  was byte-compared and passed scenario65 again.
- Independent reviewer: **15/15 units + 87/87 scenario65**, exact production/spec
  hashes matched, no remaining actionable findings. The reviewer suggested an
  `owns_root` unit-fixture guard; it was incorporated before this snapshot.
- Config-aware Lua lint: zero warnings/errors; size checks and `git diff --check`
  passed. Conservative test selection requests **all 177 front suites and base
  suites**, without relaxing dependency/coverage policy.

The integration scenario uses the real reader Calibre plugin/menu, native metadata
files, painted `Trapper` notices, actual UIManager queue registry and standby
counter. Only the transport is in-memory. It delivers real framed protocol
messages to complete initialization/device-info handshakes and book enumeration;
checks failure retries, repair, duplicate connect, menu disconnect/reconnect and
reader-close cleanup; then opens and turns a page of the inbox EPUB. A DNS guard
rejects accidental external diagnostics. Private artifacts remain under the
runner-owned profile for inspection. Unit cleanup touches only owned named files
and directories, never parent paths; modified globals/settings are restored.

### Explicit local runtime limitation

A broader seven-suite attempt, before the final fixture ownership guard, ran
**154/155** cases. The unchanged Trapper suite had one error at its existing
`C.F_GETFD` assertion: the reused local runtime's FFI declarations omit that
constant. This was not silently skipped, called green, or fixed by changing
unrelated base/production code. The separate six-suite 102/102 result above does
not include Trapper. Normal exact-head native CI must still pass the complete
selected suite, including that test, before review/merge.

Native Linux emulator assets and SDL were reused; no fresh local native rebuild,
physical Kobo/Kindle/Android test, real Calibre server, upstream write, release,
paid review add-on or gate waiver is claimed. Draft publication, exact-head CI,
included review, normal gate merge and post-merge CI remain external steps at
the time this report is committed.
