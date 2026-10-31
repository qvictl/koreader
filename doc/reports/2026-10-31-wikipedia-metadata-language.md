# Wikipedia automatic language codes from book metadata

## Provenance and bounded fix

Upstream [issue 16106](https://github.com/koreader/koreader/issues/16106)
reports Wikipedia searches using `eng.wikipedia.org`. The discussion establishes
that `ENG` came from book metadata, not an explicit Wikipedia language setting,
and points to KOReader's existing `IsoLanguage:getBCPLanguageTag` mapping.
A read-only issue/comment and pull-request search found no matching fix in the
upstream or fork. No upstream write is part of this work.

Accepted main `72f1648453e2c2f1f1e48d7a1e2b452cca52c3c0` reproduces this with
native EPUB metadata. Six private fixture variants demonstrate `ENG`/`eng` to
`eng,en`, `fra` to `fra,en`, and `jpn` to `jpn,en`; `ast` and `en-US` are controls.
The generated server follows that first code. These observations do not depend
on making a live Wikipedia request.

The two-line production change imports `IsoLanguage` and normalizes automatic
guesses after removing a region/lowercasing and before deduplication. It reuses
the existing ISO mapping for book, UI and detected languages. It does not mutate
book metadata, validate live Wikipedia domains, add a language database, or
change unknown codes. Legitimate three-letter editions such as `ast` survive.
Explicitly configured language tables retain their identity, order and values;
forced and last-selected editions are unchanged, including `zh-classical`.

## Tests and controls

- `spec/unit/readerwikipedia_languages_spec.lua`: 19 cases for known three-letter
  mappings, uppercase/region forms, `C`, existing two-letter codes, unknown codes,
  `ast`, deduplication, file-manager UI fallback, translation detection/failure,
  stable initialized lists, explicit settings and forced/remembered precedence.
  Settings, temporary method stubs and `Wikipedia.trap_widget` are restored.
- `spec/integration/scenarios/63_wikipedia_metadata_language.lua`: creates owned
  EPUBs with `ENG`, `fra` and `ast` metadata in isolated profiles and reads them
  with native crengine. Normal lookup code uses the actual intro parser and
  painted DictQuickLookup widget. Real configuration-dialog Cancel/Save, edition
  picker, close/reopen, native page turn and final FileManager state are checked.
  Module methods enter menus/lookups; subsequent buttons use real UI events.
- Only the API `loadPage` and online scheduling boundaries are synthetic. An HTTP
  guard rejects unexpected requests; images and history are disabled. The test
  proves request-language/server selection and widget behavior, not live remote
  availability, network transport or account behavior.

## Evidence

Code/test commit `3e124750c28daaee1e82109297f4e03017896b84` is based on accepted
main above. This report is a subsequent documentation-only change; the PR records
the exact publication head/tree.

- Candidate focused units: **19/19**. Nine scoped related suites passed
  **192/192**, without exclusions: readerwikipedia_languages, wikipedia,
  dictquicklookup, readerhighlight_actions, readerui_lifecycle, button, inputtext,
  readerzooming_settings and readerzooming_keyboard.
- Exact main production with the final unit suite: **8 pass / 11 fail**.
  Exact main native scenario reads `ENG` metadata successfully, then fails its
  first API-edition assertion (`eng` instead of `en`). Candidate production was
  restored and byte-compared after both controls.
- Scenario 63: **62/62**, plus **three fresh profiles with 62/62 each**.
  Ten scenarios (01/02/03/05/06/12/56/60/62/63) passed **344/344**, with all
  applicable budgets passing. Scenario 63's repeated open times were
  113/107/235 ms against a 15000 ms budget; these are local observations.
- Fresh focused unit coverage: **2/2 changed executable lines**. Configuration-
  aware Lua lint has zero warnings/errors; original unscaled-size and whitespace
  checks pass.
- Independent static review found no actionable issue and independently ran
  **19/19 units and 62/62 integration checks** in a separate private runtime with
  matching production/spec SHA256s. This is not a whole-suite certification.

The unchanged test selector chooses full unit coverage because of an opaque
external `ffi/util` dependency. Required exact-head CI, included CodeRabbit
review and the normal gate remain required; scoped local checks do not replace
them. Native assets were reused from the existing authorized Linux emulator,
not freshly rebuilt. The base gitlink is unchanged. No physical-device,
release-wide or whole-repository coverage claim is made.

## Excluded development attempts

An initial scenario used the wrong menu-table key (`wikipedia` rather than the
existing `wikipedia_settings`). It successfully exercised automatic `en` lookup
but failed when opening the settings dialog. That failed fixture attempt is
excluded from the passing totals above. Initial lint setup lacked the separate
luacheck source path; the corrected configuration-aware invocation is the clean
result reported here.
