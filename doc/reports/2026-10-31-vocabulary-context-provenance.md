# Vocabulary context follows lookup provenance

## Evidence and scope

[Upstream #13252](https://github.com/koreader/koreader/issues/13252) reports that
looking up a word inside a dictionary definition saves the original book's
unrelated selection and surrounding text in Vocabulary Builder. The fork at
`6424f249` still obtains every lookup's context from `self.ui.highlight`.
Closing the nested popup must not clear the original highlight, so highlight
ownership alone cannot identify where the new word came from.

A private SQLite control reproduces the event chain: selecting a definition word
saves the book's `migrated` sentence. The native emulator control is stronger:
a real rendered-definition long-press saves the EPUB's `keeper` selection and
its surrounding sentence for the nested word. The original book context is
valid; it simply belongs to a different lookup.

[PR #13256](https://github.com/koreader/koreader/pull/13256) proposes comparing the
lookup word with the book highlight. That is not safe to port: the supported
[edited-word workflow #12465](https://github.com/koreader/koreader/issues/12465)
intentionally allows a different dictionary stem while retaining the original
word form and example sentence. This implementation therefore uses explicit
lookup provenance, not word equality, and is not a cherry-pick of that PR.

## Narrow contract

- Add an optional final `from_definition` argument to the relevant lookup paths.
  `WordLookedUp` retains `is_manual` in its third slot; the provenance flag is the
  new fourth slot. Only explicit `true` suppresses book context.
- Definition text selections and dictionary HTML cross-links mark their new
  lookup as definition-origin. Each call, retry closure and popup keeps its own
  flag; it is not shared mutable state on ReaderDictionary.
- Preserve that flag through edited lookup text, presets, fuzzy retry,
  result-headword relookup and temporary large-window recreation. Also preserve
  it through the Wikipedia bridge, including deferred connection retry, so a
  later dictionary search cannot regain an unrelated book context.
- Both automatic capture and the real manual Add button forward the same flag.
  Root book lookups and their edited stems retain original context/word form;
  closing child popups does not discard the root selection.
- Leave book-title association, lookup history, database schema and SQL update
  policy unchanged. No extra lookup process or network request is introduced.

This prevents **new unrelated book-context capture**. It does not collect an
excerpt from the dictionary definition, repair existing incorrect records, or
change the existing `ifnull(new_context, old_context)` update policy: an existing
legitimate example is retained when a nested lookup has no book context. Default
manual searches/history/other callers without the new marker retain their old
behavior. The flag is not a transactional snapshot of all mutable reader state.

## Exact validation provenance

Accepted base: `6424f24925298dd402155f053201c81c5c8bf6b2` (main after #81).
Production/tests: `4a1ddb98225a41169b32fc8b86ea7e4d7e13b759`, tree
`4d73752c7f4a41fd1ed1a6ae6375a06fc896670b`, matching local tested commit
`fee99eb13`. A report-only successor changes no executable/test bytes. Integration
README entries 55 and 56 coexist.

| Check | Final result |
|---|---|
| New vocabulary unit suite | 32/32 |
| Seventeen focused unit suites | 208/208, no exclusions |
| Emulator scenarios 01 / 02 / 05 / 06 / 38 / 50 / 55 / 56 | 188/188 checks; applicable budgets pass |
| Scenario 56, fresh-profile repeats | 3 × 25/25 |
| Fresh unit changed-line coverage | 34/35 (97.1%); passes the 80% PR gate |
| Lua lint / original pixel-size checks / whitespace | Pass; zero warnings/errors, no policy changes |

The focused suites are `vocabbuilder_context`, `dictquicklookup`,
`readerdictionary`, `readerdictionary_history`, `readerdictionary_start_failure`,
`wikipedia`, `luadata`, `luasettings`, `hook_container`, `uimanager`, `readerui`,
`readerui_lifecycle`, `readerstatus_lifecycle`, `textboxwidget`, `imagewidget`,
`dispatcher` and `readtimer`. The normal-result `showDict` forwarding line is not
covered by the new unit suite; real sdcv integration exercises that behavior.
No combined or whole-repository coverage percentage is claimed.

Units use real private SQLite writes and real lookup/event/widget code. They
cover different/same-word nested lookups, root stem edits, manual/automatic
capture, popup and preset/fuzzy/headword variants, HTML links, the Wikipedia
bridge with deferred connection retry, interleaved lookup closures, and keeping
an existing valid context. Wikipedia API and connectivity boundaries are
synthetic; they do not issue actual network requests.

Scenario 56 opens a private EPUB and obtains a native word/xpointer/context via
`getWordFromPosition`, then constructs the book-highlight state as the root
lookup input. The nested selection uses actual `hold`/`hold_release` gestures on
rendered dictionary text. Native sdcv supplies results; real Add/Search buttons,
root/nested edits, automatic capture and reopened SQLite rows verify persistence.
Reader page turning and close/reopen remain usable. This is emulator evidence,
not physical PocketBook testing or a claim that the initial book selection was
a touch gesture.

## Controls and fixture boundaries

On unchanged actual main `6424f249`, the same 32-case suite passes 10 and fails
22 assertions; these are propagation/compatibility controls, not 22 distinct
reported bugs. The unchanged-code native scenario fails on the saved nested row:
it contains the book's original `keeper` context rather than no book context.
The root-word capture already passed immediately before that failure.

Earlier fixture mistakes were corrected before the final runs: missing SDL
runtime path, the plugin's registered `vocabbuilder` key, dictionary button
lookup and waiting for a genuinely shown new popup rather than a closed stale
`dict_window` pointer. These exploratory failures are not counted as successful
runs or product defects. An initial related-unit attempt also lacked the
standard `sample.txt` fixture and a test-file overlay; both were restored before
rerunning all seventeen suites. `sample.txt` came from the exact pinned test-data
commit `c3b5d06e1ae8ea088bd898b0e7f9da3753d0d86c`, with verified Git blob
`15d7805fe03e61bc92d6e4b9d47fd75ef007dfa6` (3,638 bytes), not an invented replacement.

The unit fixture restores settings/module caches and temporary method overrides,
and owns only its private SQLite directory. The integration fixture restores
settings before cleanup, protects each popup close and reader close independently,
then checks that no dictionary popup remains and FileManager is usable. Private
EPUB/profile inputs are retained for diagnostics and possible queued workers.
No dictionary installation/download workflow or unrelated link-path investigation
is part of this change.

Existing authorized native emulator assets were reused; this is not a fresh
native rebuild, release-wide test pass, or physical-device certification.
Independent source/log review found no new blocking issue and did not rerun the
runtime. Exact-head CI, formal included review and the normal merge gate remain
required separately.
