# Calibre search / wireless metadata isolation

## Source and evidence

[Upstream issue 13583](https://github.com/koreader/koreader/issues/13583)
reports Kindle crashes while sending or deleting books, with metadata-search
messages immediately before `rapidjson.dump` receives a nil filename. A later
comment identifies the shared mutable metadata singleton as a possible cause.
The same sharing remains in fork main `3933787fb891befec8b6e2088f9b67db8da5595c`.

A controlled, real-library reproduction confirms this specific mechanism:

1. Start the normal wireless connection coroutine and initialize its inbox.
2. Search the inbox or a different Calibre library through `Search:getMetadata`.
3. The search overwrites the singleton and then calls `clean`, clearing the
   wireless book list, metadata filename and drive-information filename.
4. Wireless enumeration incorrectly reports zero books. An incoming metadata
   update, received-book completion, drive update or deletion tries to save with
   a nil filename and throws the reported exception.

The initial seven regression cases all fail with original production: two wrong
book-count assertions and five real `rapidjson.dump` exceptions. The real
emulator reproduces the same nil-filename traceback after a painted Calibre
search/results menu and the next incoming metadata update. Its integration
harness catches the exception and records a failed scenario.

This does not claim that every historical report in the upstream thread shares
this cause. Oversized metadata, unwritable inboxes, native/server errors and
atomic-save durability are separate concerns, unchanged here.

## Fix

Add a small `CalibreMetadata:new()` constructor with fresh JSON-array tables,
and let the two production consumers, Search and Wireless, each obtain their
own instance. Their public workflow and cleanup remain unchanged. Search still
uses slim metadata and does not rewrite searched libraries; wireless retains its
UUIDs and full slim fields. Disconnect still intentionally invalidates the search
cache, while cleaning only wireless metadata state.

This is per-consumer ownership, not a new concurrency/locking scheme or a claim
of independent simultaneous wireless connections. Both consumers are otherwise
existing singletons. No network protocol or file-write format is changed.

## Validation

- **23/23 native tests:** 11 new ownership cases plus all 12 existing Calibre
  wireless collection cases. Coverage includes incoming metadata/drive updates,
  book receive/delete, same- and other-library search, repeated reconnect,
  missing/invalid search metadata, two-library snapshots, fresh array ownership
  and cleanup isolation.
- Original production fails every initial seven regression cases. The new
  constructor-specific tests are not used as sole evidence of the old bug.
- **6/6 changed executable lines covered, 100%**, using the unchanged repository
  diff-coverage gate. Whole-repository coverage is not measured.
- `41_calibre_metadata_isolation`: **23/23**, three fresh local runs. It uses
  actual connect/metadata/search/receive/delete code and synthetic private disk
  libraries. Searches paint their real results menu. Incoming file bytes,
  metadata, UUIDs, unrelated-library preservation, reconnect, and opening/turning
  a page in the received EPUB are checked. Only the transport is synthetic; no
  Calibre server or real device is contacted.
- Independent local review: no blocking finding; 23 tests and three additional
  scenario-41 runs pass. Its four added edge cases are incorporated.
- Integrated actual merged main `b8c3a285` (sidecar/base helper, collections,
  XMNote and gesture), retaining README scenarios 38/39/40/42/44.
  The combined native validation passes **169/169** tests across eight suites
  (Calibre ownership/collections plus gesture/Input).
- Final combined emulator validation runs scenarios 02/03/16/40/41/45 three
  times each: **420/420 checks, 15/15 English/CJK responsiveness budgets**.
  Scenario 40 includes both retained-slot late-axis cases from gesture review.
- Lua lint and `git diff --check` pass.

All **159 front suites** were attempted in separate Busted processes against
that final production combination: **156 suites pass, with 2,246 successful test
cases**. Three suites hit unchanged host restrictions: missing `msgfmt`, one
prohibited `getifaddrs` assertion, and four live-Internet translator DNS errors.
These restrictions were not bypassed. This is not a clean full-suite pass;
exact-head required remote CI/build/CodeRabbit gates remain required.

## Runtime / delivery boundary

All 500 production Lua overlay files are checked against candidate source. Native
emulator binaries are reused from the existing fork artifact, with unchanged
native base binaries and all 92 FFI Lua files matching the actually merged
base `d1b27196eac53e8c810c63762ed6bfb40f226382` (Lua-only helper change). The held
base PR 36 is not included. SDL3 is the existing isolated 3.4.18 library. This is not a fresh native or Kindle build, live Calibre protocol
acceptance test, or hardware validation.

No upstream communication, release, device installation or gate change is part
of this fix. Publication and included public-fork review may proceed through the
existing gates; no paid add-on activation is authorized.
