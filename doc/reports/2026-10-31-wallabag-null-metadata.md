# Wallabag: tolerate null title and original URL metadata

## Upstream evidence and scope

- [Issue #14147](https://github.com/koreader/koreader/issues/14147) reports that an
  article sync stops after several successful downloads. The logged failure is
  a filename string operation receiving a function.
- The [maintainer diagnosis](https://github.com/koreader/koreader/issues/14147#issuecomment-3214383068)
  identifies `article.title` containing the JSON-null sentinel, not the initially
  suspected MIME type. Our JSON decoder represents null as a **truthy function**.
  Consequently, the later suggested `article.title or ""` does not guard this case.
- The isolated fixture reproduces that failure with actual `JSON.decode` on
  accepted fork main `30ec400edb1421ddec6837f2f1d8f959290f7593`.
  This establishes the metadata-type crash, not every possible cause of empty
  articles, service-side extraction failures, or a particular device's state.

## Narrow production change

`plugins/wallabag.koplugin/main.lua`, `downloadArticle` only:

1. Pass only string titles to the existing filename sanitizer; other values use
   the existing empty-title fallback. The stable `[w-id_ID] ` prefix remains,
   preserving inventory identity and distinguishing untitled articles.
2. Enter original-document selection only when the original URL is a string.
   Otherwise retain the existing per-ID EPUB export endpoint, even when MIME
   metadata names a supported original format.

Normal titles, filename sanitization, MIME normalization, original-document
preference, HTML-to-EPUB selection and extension handling remain unchanged.
No remote article metadata is modified. No schema, archive/removal policy,
authentication, retry scheduler, file-write atomicity or download transport is
changed. A `downloadArticles` true result means the loop reached its summary,
not that every requested export succeeded.

## Regression tests

### Unit: `wallabag_null_metadata_spec.lua`

13 cases use actual JSON decoding and private local regular files. Only the API
boundary and UI display are replaced:

- Null and absent titles, ordinary titles and the stable ID filename.
- Null and absent original URLs, with null or PDF MIME metadata.
- Valid original URL selection by suffix and MIME, including MIME parameters.
- Null title with a valid original PDF URL; ordinary HTML still exports EPUB.
- A three-article batch proceeds past the null title; a second sync skips all
  successful files without rewriting their contents.
- A failed middle export does not stop the later article or enter the inventory;
  the next sync retries only the missing entry.

Fixtures are created only after absence checks, tracked for cleanup, and global
UI overrides are restored before deleting only the owned files. The unit export
bytes are synthetic text, not claimed to be valid EPUBs.

### Emulator: `58_wallabag_null_metadata`

The real TouchMenu callback dispatches `SynchronizeWallabag` through the plugin.
Cached synthetic credentials avoid authentication; only online availability and
`socket.http.request` are intercepted. The list is raw JSON and the export path
uses the real API response sink, filename generation, inventory scan and cleanup
of a simulated HTTP 503 response. No live network or Wallabag account is used.

The first batch preserves the successful article before the failing untitled
entry and downloads the following article. Retry fetches only the missing ID,
then another sync skips all three. Existing annotation bytes remain identical.
A fixture EPUB is delivered through the real sink, then opened, navigated,
closed and reopened by the native reader. Every test request must match the
private synthetic endpoint allowlist and carries no real credentials.

During synthetic configuration, the instance's dirty flag is overridden to
false, and an explicit real settings flush must preserve both shared settings
identity and current disk bytes. All plugin fields are restored before closing
the old FileManager creates a reader; the new reader and replacement FileManager
must inherit the original configuration. The original configuration may undergo
its normal first persistence, so final file absence/byte identity is not claimed.
Cleanup restores plugin fields first, independently closes tracked messages,
menu and reader, then restores global methods. Private input books remain until
process teardown so queued native work cannot outlive its input. This is not a
physical-device or actual-server test.

## Validation and provenance

The independent review found a test-isolation gap in the initial scenario:
closing the first FileManager dispatched `FlushSettings` while its initial dirty
flag was true, persisting synthetic credentials into the test profile and shared
plugin settings. This is a test-fixture issue, not a production fix. Test-only
successor `d7c518f8345fddc0069c2c736a7b71334cd81862` (tree
`47a8bd640e98f72464d27274a9075522e3645f00`) adds the protections described above.
The final scenario passes **3 × 28/28**; removing just its dirty-flag override
fails the new shared-settings assertion (**20/21**). Completed profile settings
contain no synthetic endpoint/credentials. Production and all 13 unit cases are
unchanged from the initial snapshot below.

### Earlier main-82 combination, before test-isolation strengthening

Initial code snapshot `e13d1b7ba20bc757567955c29420487f2ae55444`, tree
`f1891aa3fa11c094eaf3c36b9845b1a1c9b356ac`, based on accepted main 82:

- New unit tests: **13/13**.
- 13 full related suites: **199/199**. Additional network-flow suite: **72/73**;
  its existing loopback-address test fails because this host denies `getifaddrs`
  with `EPERM`. An explicitly filtered rerun passes **72/72**. No test assertion,
  product code or permissions were weakened to hide that limitation.
- Eight emulator scenarios: **152/152** checks, applicable budgets passing:
  `01`, `02`, `16`, `36`, `42`, `44`, `56`, `58`.
- Scenario 58: **3 × 24/24** in fresh profiles.
- Fresh changed-line unit coverage: **3/3 (100%)**, above the 80% PR gate.
- Original lint: **0 warnings/errors/fatals**; size and whitespace checks pass.

Exact-main control with the same final tests: **6/13 pass, 2 assertion failures,
5 errors**. The actual menu scenario stops before the sync summary; its logged
handler failure is the same string-operation/function mismatch. These are test
failures for the narrow bug family, not seven distinct reported device bugs.

The first emulator attempt accidentally formatted binary EPUB bytes into a
check message, producing a non-UTF-8 JSON result. It is excluded from passes;
using boolean byte-equality assertions fixes the test reporter issue. An early
local lint invocation targeted another candidate's fixed file list and reported
missing-file fatals; the corrected, configuration-aware invocation above checks
all three new/changed Lua files. Neither harness issue changed product behavior.

Related native fixtures reuse existing local emulator assets; no new executable
was downloaded and no native rebuild is claimed. The standard sample PDF and
DjVu were copied from an already verified runtime only after checking their Git
blob IDs against the pinned test-data provenance. The test environment is not
representative device storage, and these measurements are not release coverage
or full-repository test results. Exact-head CI and formal review remain separate
merge gates.

### Main-82 isolation-strengthened snapshot (historical)

Published code/test object `ae4d378b415e2da84fff2cf49d21fbab15a7b985` has tree
`47a8bd640e98f72464d27274a9075522e3645f00`, equal to local tested `d7c518f8345`.
The report-only successor changes no executable/test code. A fresh final rerun
of the same 14 selected suites passes **271/271**, with only the explicitly
excluded, previously failed host loopback case described above. The same eight
emulator scenarios pass **156/156**, now including all **28/28** isolation checks
in scenario 58; applicable budgets pass. Its fresh-profile repeats are **3 ×
28/28**. Unit coverage remains **3/3**, and final lint/size/whitespace checks pass.
These final results do not reattribute the earlier 24-check scenario to the
isolation-strengthened fixture. Independent source/log review is separate from
runtime execution, and normal exact-head CI/formal review remain required.


### Latest accepted main-83 combination

Accepted main is now `0531bd8ad57d42b69787a0b1ae0052f6296b5ab8`. Integration
README rows **57 and 58** are both preserved. The candidate's three production/
test Lua files are unchanged from `d7c518f8345`; the integration is with actual
merged main, not an unmerged dependency.

Published merge/code object `214a59c8501d8e7a1feb94ea8f076289f2726c5d`, tree
`8ed55c514c0de2a26663e32cf076b6ef54822d74`, equals local tested combination
`a08730cb24a681676229d7e3abdab6f81b5eee35`. The following report-only successor
contains no further source/test change. Fresh validation on this combination:

- **13/13** candidate unit tests; **294/294** across 15 selected suites, adding
  the accepted keyboard-zoom suite to the prior list. The single existing host
  loopback-address exclusion remains explicit and unchanged.
- **184/184** checks across nine emulator scenarios: prior eight plus **57**.
  Applicable budgets pass; scenario 58 repeats **3 × 28/28** in fresh profiles.
- Fresh candidate changed-line unit coverage **3/3**; lint **0**; original size
  and whitespace checks pass.
- Exact-main-83 control rerun: **6 pass / 2 failures / 5 errors**; real menu still
  fails before its sync summary with the filename string/function mismatch.
  Candidate production is restored and compared afterward.

These are the latest combination results; the earlier 271/156 and 199/152
figures remain historical, not duplicated or added into the final totals.

### Review-driven update-path limitation

This PR only fixes title and URL metadata type handling. **Same-ID updates after
renaming or changing formats, and migration of their reading state, remain
unresolved when dateparser is enabled.** The null guard lets an input that used
to crash complete its initial download; it does not make later updates safe.

A separate private characterization used the real date parser, a future
`updated_at` of `2099-01-01T00:00:00Z`, actual `callAPI`/ltn12 file sinks,
synthetic HTTP responses, ordinary private files and real DocSettings:

- Both main `0531bd8a` and the candidate produce a second file for a legal empty
  string title becoming `Renamed`, or `Original` becoming `Renamed`. The old
  file and sidecar bytes remain, but the new inventory path has neither the
  original annotation nor the saved 40% reading progress.
- The candidate's JSON-null-to-`Renamed` case reaches the same existing defect;
  main instead fails on the initial null title's function/string operation.
- A private simulation of simply substituting the old destination path, without
  changing production, loses the previously successful file on HTTP 503:
  `io.open(..., "w")` truncates it and failed-download cleanup removes it.
  Directly reusing an old path is therefore not an acceptable fix.

The candidate's four characterization cases observed these expected defects and
counterexamples; main observed the same three existing behaviors and the null
case's initial error. These are **not passing guarantees of update integrity**,
are separate from the 294-unit/184-integration validation above, and used no live
service or user article. Native EPUB reading was not part of this characterization.

A follow-on update transaction needs independently validated streaming temporary
output, success confirmation and safe same-format replacement, with failed
requests retaining existing files and metadata. Format changes require an
explicit policy: PDF bytes must not be stored under an old `.epub` extension,
and retained sidecars do not establish cross-format anchor compatibility.
No such transaction, migration or production path-reuse change is included here.
Formal review accepted this limited scope but normal latest-head approval and
required checks remain separate gates.
