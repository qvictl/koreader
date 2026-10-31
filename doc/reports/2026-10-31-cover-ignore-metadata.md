# Preserve cover preferences during custom text metadata edits

## Scope and reproduction

Upstream [#12588](https://github.com/koreader/koreader/issues/12588) reports that
editing a custom title or author resets “Ignore cover”. The same cache deletion
also loses the independent “Ignore metadata” flag.

A private native-SQLite characterization on accepted main #92 `a7f4a2f3` followed
`BookInfo:show` → `setCustomMetadata` → the real KeyValuePage close callback →
`CoverBrowser:onInvalidateMetadataCache`. The custom title was saved correctly,
but the entire cache row, including both ignore flags, was deleted. The owned
fixture used no real user book, account, network service or shared cache.

The correction forwards the edited key/value through the existing invalidation
event and updates that single cached text-metadata column. Resetting a field to
an absent original value uses the existing setter's SQL NULL convention. This
retains row identity, native cover data and independent ignore choices. No
schema, sidecar-writing strategy, file replacement or database transaction API
changes are introduced.

Custom cover changes, callers requesting generic invalidation without a key,
and explicit cache refresh/delete operations still remove the cache row as
before. Missing cache rows are not synthesized, and incomplete extraction rows
are not marked complete. This is not a fix for concurrent background extraction
later replacing a row, nor a promise to refresh unrelated already-stale fields
or covers. Those existing cache lifecycle concerns remain outside this patch.

## Candidate and accepted-main synchronization

- Initial code/tests: `2754623c1`, tree `df1978fb` on actual #92 main.
- Merged accepted #93 main `406307df` normally; both scenario README rows 66 and
  67 retained. Combined code/tests: `732d85b96`, tree `8e5f56cc`.
- Both production files, unit suite and scenario 67 are byte-identical across
  that synchronization; only accepted OPDS files and README row 66 were added.
- Required CI, formal AI review and merge-gate outcomes are recorded on the PR;
  local results below are not a full-repository, release or hardware certificate.

## Local verification

### Unit tests and unchanged behavior

`spec/unit/cover_ignore_metadata_spec.lua` contains 37 cases using private native
SQLite and real BookInfo/custom sidecar operations:

- All seven editable metadata fields × all four independent ignore-flag states.
- Exact cache identity/cover-byte preservation, current cached/custom values,
  event order/payload, repeated edits and database close/reopen.
- Reset to an original value and absent original/SQL NULL.
- Missing and in-progress cache rows.
- Existing cover, generic and explicit full-deletion semantics.
- Actual edit-dialog Cancel, without changing native text-input state.

The off-stack unit widget fixture isolates/restores Device text-input methods
and virtual-keyboard settings and identifies the input dialog by its input
widget. Directory ownership is asserted before creation and checked before
cleanup. Production input handling is not mocked by the integration scenario.

- New suite: **37/37**.
- Related first selection: **150/150 across 12 complete suites**, including
  cover list/lifecycle, BookList, DocSettings/location/migration/sidecar,
  FileManager/close-windows, and coverimage format/bootlogo regressions.
- Final accepted-main unit selection: **183/183 across 13 complete suites**, adding
  the accepted OPDS credentials suite; 506 tracked frontend/plugin files were
  byte-compared to the combined source snapshot.
- Fresh changed-line unit coverage: **7/7 (100%)**, above the normal 80% PR gate.
  Whole-repository/release coverage was not measured locally.
- Config-aware lint: **0 warnings/errors/fatals**; whitespace and repository
  unscaled-size checks passed. Conservative selector requests full CI.

### Real emulator integration

Scenario **67_cover_ignore_metadata** uses native EPUB metadata/PNG extraction,
the SQLite cache, painted file rows, real FileManager Ignore/Unignore and Book
information buttons, custom title/author input Save/Cancel, Reset confirmation
Cancel/Reset, database reopen, native EPUB page turns and reader reopen. It
checks the exact cached cover bytes without embedding them in JSON reports,
cover-file survival and the independent displayed title/cover preferences.
No metadata extraction or SQL operation is stubbed. Native workers are reaped;
UI state is closed before restoring input flags; owned inputs remain available
through process teardown, including cleanup failures.

- Final scenario: **106/106**, edit budget **131/5000 ms** in the initial final
  run; **3 × 106/106** fresh-profile repetitions,
  edit budgets **120, 144 and 107 / 5000 ms**.
- Related integration selection: **776 checks passed across 16 passing scenarios**
  in the broader 17-scenario attempt described below.
- Final accepted-main OPDS/metadata selection: **129/129 in scenarios 66 and 67**,
  with the accepted OPDS production change present.

The broader first 17-scenario local attempt included existing scenario 17
(document regressions). It failed before any checks at its RGB565-to-RGBA
buffer-stride assertion in the reused local native/FFI runtime. No scenario 17,
base implementation or assertion was modified or disabled for this task.
This failed invocation is not counted as validated. The ordinary required CI
must build/test its own complete checkout; local scoped successes do not waive
that gate. Native assets here were reused, not rebuilt.

### Negative controls and independent review

Restoring both production files to actual #92 main, unchanged in #93, gives
**4 passing / 32 failing unit cases plus 1 error**. The real-menu integration
gets through Cancel and both Save actions but then fails because the cache row
has disappeared (43 prior checks pass). The original one-case characterization
also verifies the saved custom title alongside loss of both ignore flags. The
negative runtime is separate from the candidate; no candidate run uses the
restored production files.

An independent reviewer examined `2754623c1`, verified matching production/unit
hashes, and independently passed **37 units + 106 integration checks** in a
private runtime (edit **153/5000 ms**). A unit-only text-input isolation finding
was fixed before that final run. No actionable findings remain. This independent
review did not repeat the broader selection, negative controls or full CI.

## Commands and evidence boundaries

The local unit invocations used `spec/runtests --busted [--coverage] front` with
explicit full `spec/front/unit/*_spec.lua` filenames; no zero-case invocation is
counted. Integration used `tools/run_integration_tests.sh` with unique output
profiles, the isolated candidate runtime and workspace-local `TMPDIR`.

Private evidence is indexed in `cover-ignore-metadata-validation.json` in the
engineering workspace. It includes the baseline, negative controls, unit logs,
coverage, emulator JSON/screenshots and independent review paths. No private
runtime/artifacts are committed. The PR is opened as draft; exact-head required
CI, one included review and the unchanged normal merge gate remain mandatory.
No upstream write, manual review-thread resolution or paid add-on is used.
