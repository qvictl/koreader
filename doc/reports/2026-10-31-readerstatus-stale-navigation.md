# Reader navigation: discard callbacks from a closed document

## Upstream evidence and reproduction

[Upstream issue 15576](https://github.com/koreader/koreader/issues/15576) reports a crash when rapidly opening the next or previous PDF. Its [later verbose log](https://github.com/koreader/koreader/issues/15576#issuecomment-5855300512) shows the reader closing immediately before `filemanagerutil.openFile` tries to call a missing `openFile` method from a ReaderStatus task.

The current fork reproduces that stack with private, generated PDFs and the real reader/task queue. ReaderStatus defers navigation until the next tick. Two requests can both retain the same ReaderUI; the first closes its document, and the second sees `ui.document == nil`. The shared helper then mistakes that old reader for a FileManager.

Independent review found a second entry to the same failure: with “Ask to open” enabled, both queued requests can create confirmation dialogs while the original reader is still alive. The first confirmation closes that reader, but the second modal intentionally survives reader closure and retains its callback. Guarding only the next-tick task does not protect the later confirmation. A real second-button tap reproduces the same missing-method error.

## Scope and compatibility

- The ReaderStatus next-tick task checks that its original document is still attached before attempting navigation.
- The shared open-file helper captures a non-nil originating document. Its callback checks that identity before running the caller's pre-open callback, and again afterward in case that callback changed the lifecycle.
- FileManager callers have no originating document and retain their existing behavior. Live-reader switching, auxiliary providers, forced-provider arguments, pre/after-open callbacks and explicitly bypassed confirmation remain unchanged.
- Stale confirmations dismiss normally without reopening a book or invoking an old menu callback. Cancel remains Cancel. No navigation is redirected to whichever reader happens to be active later.

This is eight added production lines across two files. It does not redesign general ReaderUI lifecycle, change file selection/order, alter filesystem operations, or claim to handle every possible call made with an already-invalid UI object.

## Exact validation attribution

Final-combination results below apply to snapshot `3686b080a25e294bd6014a21c6f95b1901d7547f`, tree `74914a6827c35dc7bca2da17fe29c2f00af3b156`, incorporating accepted main `4e220d167c8ae21f30ba50974c62382b9fd18bb2` and its base pin `fcdb4d77`. The remote tree was verified to equal the tested local tree. The next commit changes only this report.

The earlier main-75 snapshot `9a64d72284e75f9427f0fff997b694d79de8f59b` (tree `b37de5c077ed2649c2173ef826cb1fdeb89eef9e`, base `5cdadae48`) passed 296 unit cases and 98 integration checks. Its scenario-50 repeat run is attributed separately below. The candidate production and test files are unchanged in the newer combination; the merge preserved README rows 48/49/50, added the accepted proxy fixture and updated the base pin.

| Check | Result |
| --- | --- |
| New unit suite | 16/16 passed |
| Related suites on the final main combination | 296/296 passed across 17 separate processes |
| Changed executable coverage, fresh unit-only statistics | 4/4, 100%; whole-repository coverage unmeasured |
| Native PDF lifecycle scenario 50, earlier main-75 repeat run | 3 fresh profiles, 36/36 checks each |
| Final main-74 combination, scenarios 01/02/09/16/18/48/49/50 | 141/141 checks; applicable existing budgets passed |
| Lua lint | zero warnings/errors |
| Whitespace validation | `git diff --check` passed |
| Independent review | static source/log review found no remaining blocker; no independent native rerun claimed |

The 17 related suites cover ReaderStatus, the newly accepted PocketBook cover preference, ReaderUI/core lifecycle/password cancellation, FileManager/core operations/window cleanup, FileChooser/core sorting, BookList, document registry/document, DocSettings/core locations, Dispatcher and UIManager. These are focused regression suites, not a full repository test run. The final combination also executes the accepted real-loopback HTTP proxy scenario 49. Its LuaSocket module was copied into the private runtime after verifying SHA-256 `d0e02b15f926cfff7989dbf3f6ed0d26a3f939f9fe1d40f9f3d2520e788da579`, matching the generated module from the accepted base pin. Native engine binaries were not rebuilt or changed.

### Negative controls

- The final 16-unit suite against unchanged production yields eight passes, two assertion failures and six errors. The errors include the same missing `openFile` method, rather than a different test setup failure.
- Unchanged production crashes the real PDF scenario during its first repeated next-file requests, before scenario completion. The stack matches the upstream ReaderStatus/task/helper chain.
- Keeping only the next-tick guard leaves the confirmation defect: twelve unit tests pass, one fails and three error; the real scenario reaches its duplicate modals, then fails when the second old confirmation is tapped.

The two production files in those unchanged-code controls are identical between accepted main `8e5dac18` and `5cdadae48`. Earlier successful focused runs on the former base (281 unit cases and 81 integration checks) are superseded by the final-combination results above, not added to them as new coverage.

### Scenario behavior and isolation

Scenario 50 generates three small, deterministic three-page PDFs in its fresh KO_HOME. MuPDF loads/renders them through real ReaderUI instances. It exercises repeated next and previous requests, Home before the queued callback, an explicit replacement book before the old callback, two real confirmation dialogs tapped in succession, cancellation, confirmation after Home, ordinary FileManager confirmation, native page turns and reading-position persistence after reopening.

There are no production method, SDK or filesystem mocks in this scenario, no network operation and no downloaded document. The temporary confirmation setting is restored before protected cleanup; owned modal dialogs and any surviving reader are closed. Private inputs remain until process teardown so a normal background worker cannot lose its input file.

Early harness iterations exposed an incorrect page-turn assumption under the default continuous PDF view, a zoom warning consuming the next tap, and a local gettext alias shadowed by a loop index. Those were fixed in the harness, and the failed runs are excluded from the passing counts. An initial broad unit run also lacked the existing official `2col.pdf` and `paper.pdf` fixtures; after restoring private copies, every listed suite was rerun successfully. Assertions were not weakened to hide those setup failures.

## Limits and gates

The native engine/runtime comes from the owner-authorized Linux emulator. No physical Kobo, Kindle, PocketBook or other device was exercised, and this is not a newly rebuilt native-engine validation. The repeated/interrupted flows are deterministic lifecycle tests, not a proof against every possible UI race.

Publication is draft-first. Exact-head CI, changed-line coverage and the normal included CodeRabbit/review gate remain required before merging. No paid add-on, manual approval substitution or upstream write is involved.
