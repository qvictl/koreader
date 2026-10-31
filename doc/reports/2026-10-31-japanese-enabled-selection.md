# Japanese selection honors dictionary scope

## Provenance and scope

Upstream [issue 15376](https://github.com/koreader/koreader/issues/15376)
reports that a disabled Japanese dictionary can make a held word expand to a
longer entry that the subsequent lookup cannot find. In the reported example,
`適当に` is selected even though the only enabled dictionary has `適当`.
The issue discussion distinguishes this from intentionally preferred dictionaries.
A read-only upstream PR search found no matching fix during this investigation.

The fork's accepted main `6692adeedb62653c0ace6d80b49686f61c585b60`
retains `Japanese:onWordSelection` calling `rawSdcv(all_words)` without names.
The normal lookup restricts results to `enabled_dict_names` (including available
book-preferred dictionaries) and then removes `doc_disabled_dicts`.
The selection and lookup therefore disagree.

The fix copies that effective scope into a fresh array and passes it to sdcv.
An empty effective scope returns without launching sdcv, because omitting `-u`
options means *all installed dictionaries*, not zero. Candidate generation,
deinflection, punctuation handling, scan limits, cancellation and dictionary
ordering are unchanged. The stored arrays and per-book table are not modified.
No downloader, installation, network, native dictionary parser, lookup transport,
review policy, CI policy or upstream repository is changed.

## Tests

- `spec/unit/japanese_selection_spec.lua`: 14 cases using real candidate generation
  and deinflection with a synthetic sdcv response boundary. Covers the reported
  shorter/longer match, global and book disabling, preferred order, missing
  book-disable table, every-dictionary-disabled early exit, repeated toggles,
  conjugated words, no matches, cancellation, nil results and language guards.
- `spec/integration/scenarios/60_japanese_enabled_selection.lua`: actual crengine
  Japanese EPUB, hold gestures, native sdcv, dictionary popup, painted Manage
  installed dictionaries checkbox and Cancel/Save controls, book-preferred
  dictionaries and the preferred-dialog hold event, settings persistence through
  closing/reopening, all-disabled no-query behavior and recovery.
  Two tiny synthetic StarDict dictionaries and a private book copy are created
  under the isolated test profile; the test temporarily overrides only the
  dictionary-root default and restores it. No user dictionaries or downloads.
- Related integration scenarios: 01/02/03/05/06/12/56/60. Native assets are the
  existing authorized Linux emulator assets with current Lua source overlaid;
  they are not a new full native build or physical e-reader test.

## Evidence

Initial source/test commit `8763b372ca86f18ee6f9576a07e1f17d6451a352`
was based on main-83 `0531bd8ad57d42b69787a0b1ae0052f6296b5ab8`.
Main-84 was then merged as `6aa95a6f25bc21837cb613b169b62d47fac1accf`
(tree `b443ad524e7de8e28e38dd059cc5b995bb7c6abb`), retaining README scenario 58
alongside 60. The Japanese production and test files did not change in that merge.

- Initial focused unit run: **14/14 passed**.
- Exact main-83 production control with the new unit suite: **5 passed / 9 failed**.
  Some failures assert the explicit dictionary scope, not only selection length.
- Corrected integration: **55/55** checks; final hold-event version repeated on
  **three fresh profiles, 55/55 each**. Selection timings reported for those runs
  were 7, 11 and 13 ms (5,000 ms budget), not device performance claims.
- Related integration pass: **157/157 checks across eight scenarios**, with all
  applicable budgets passing.
- Exact main-84 production control plus the new scenario fails at the real global
  disable action: after disabling the long dictionary, `吾輩は` remains selected
  instead of the available `吾輩`. The earlier both-enabled and Cancel controls pass.
- Configuration-aware Lua lint: **0 warnings, 0 errors**. Original unscaled-size
  checks and `git diff --check` pass.

After main-84 reconciliation, the nine-scenario pass (the eight above plus 58)
passed **185/185 checks**, including 55/55 in scenario 60; all applicable budgets
passed. Both initial and main-84 11-suite scoped unit runs passed **239/239 cases**.
A fresh main-84 focused coverage run passed **14/14** and covered **7/7** changed
executable lines. The exact remote head/tree are recorded in the PR. The repository test selector conservatively requires
**full unit tests**, because the changed plugin imports opaque external Lua
`ffi/util`; this behavior is preserved, not bypassed. Scoped local validation is
not a substitute for that full CI run, native builds or release coverage gates.

## Excluded or unsuccessful development runs

The first integration fixture tried to hold text while the preferred-dictionary
notice was still on top; that input correctly went to the notice. The scenario
now explicitly dismisses the notice before another hold. That run is excluded.
An initial broad local unit command was canceled during its sdcv suite before
reaching the dictionary settings suite, which also contains downloader cases.
The complete settings/downloader suites are excluded from the final scoped local
command, and coverage was reset before the final rerun. The full required CI
remains independent. An attempted coverage report before the unit runner flushed
its statistics had no input and reported 0/7; it is not validation evidence.

No physical Kindle/Kobo behavior, full-release coverage ratchet, fresh native
rebuild or whole-repository local test pass is claimed. Normal draft publication,
exact-head CI, one included CodeRabbit review and the unchanged review gate remain
required before merge.
