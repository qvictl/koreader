# PDF current zoom survives partial setting updates

## Provenance and root cause

Upstream [issue 15977](https://github.com/koreader/koreader/issues/15977)
reports setting the global PDF zoom factor to 2 and the current book's factor
to 0.7, then finding that the next page uses 2 again. Closing/reopening or
switching modes temporarily avoids the problem. A read-only issue/comment and
open-PR search found no matching fix. The fork's merged keyboard-zoom PR 83
addresses a different free/manual navigation and preview problem; its tests
remain compatibility controls here.

Accepted main `edb652a5c5ffd023e1db85caffa1c5df34b538d3` reproduces the bug.
`onDefineZoom` first calls `setNumberOf`, which stores the current factor and
redraws. It then sends another `SetZoomPan` containing mode/direction/overlap
but no factor. `onSetZoomPan` unconditionally saves both persistence keys;
saving nil removes the factor just stored. The next page's `getZoom` therefore
falls back to the global default. Factor-only and overlap-only calls also
remove omitted mode/factor keys. No production caller intentionally requests
nil deletion through this partial-update API.

The fix saves each persistence key only when supplied. It does not change the
zoom/default precedence, scale calculations, redraw contract, keyboard handlers,
preview modes, native rendering, global configuration, or CI/review policy.

## Tests and controls

- `spec/unit/readerzooming_settings_spec.lua`: 15 cases with real native PDF
  ReaderUI instances and private synthetic three-page PDFs. Covers current
  factor across page changes, mode-only/factor-only/overlap/direction/empty
  updates, explicit replacements, repeated values and reopen, columns/rows,
  absent keys, no global override, and no-redraw behavior. Global default,
  input state, plugin state and owned book files are restored/cleaned.
- `spec/integration/scenarios/62_pdf_current_zoom_factor.lua`: real bottom-menu
  configuration pickers, painted arrow taps, default confirmation Cancel/Save,
  Apply and Close without Apply, native tap page turns, overlap-only changes,
  close/reopen and another book inheriting the unchanged global default.
  Menu/picker entry uses normal module methods; subsequent controls use real
  UI events. PDFs/settings are owned by isolated test profiles. No network,
  downloads, external documents, shell commands or physical device operations.
- Existing `readerzooming_keyboard_spec.lua` and scenario 57 exercise PR 83's
  page/continuous/preview compatibility instead of replacing those assertions.

## Evidence

Code/test commit `21cf39a6db89375142b9abbd56c4f007be40c43d` is based on the
accepted main above. Exact final publication head/tree are recorded in the PR;
this report is a subsequent documentation-only change.

- Candidate: **15/15** focused units; **38/38** including all 23 existing
  keyboard-zoom cases. Ten scoped related suites passed **221/221**, without
  exclusions: the two zoom suites, readerpaging, readerpaging_nav,
  readerui_lifecycle, readerhighlight_actions, button, document_registry,
  document and docsettings.
- Exact main production with the final focused suite: **7 pass / 8 fail**.
  The user-facing case changes scale from 1.89259 to 5.40740 on the fixture's
  next page instead of preserving it. Other failures check deleted settings.
- Scenario 62: **125/125**, repeated on **three fresh profiles, 125/125 each**.
  Nine related scenarios (01/02/03/07/28/50/57/60/62) passed **309/309**, with
  all applicable budgets passing. Existing scenario 57 contributes 28 checks.
- Exact main native-UI control successfully sets default 2 and current 0.7
  through the same widgets, then fails the next-page scale assertion.
  Candidate production is restored and byte-compared after negative runs.
- Fresh focused unit coverage: **4/4 changed executable lines**. Configuration-
  aware Lua lint has zero warnings/errors; original unscaled-size and whitespace
  checks pass.
- Independent static review found no actionable finding and independently reran
  **38/38 units and 125/125 integration checks** in an isolated runtime, matching
  production/spec SHA256s. This is not an independent whole-suite run.

The repository selector still chooses full unit coverage because ReaderZooming
imports opaque external Lua `ffi/util`; the policy is not weakened. Scoped local
results do not replace required exact-head CI. Native assets are reused from the
existing authorized Linux emulator, not freshly rebuilt; base gitlink is unchanged.
No physical e-reader or release-wide/whole-repository coverage claim is made.
Normal draft publication, required CI, included CodeRabbit review and the
unchanged review gate remain required.

## Excluded development attempts

The first unit invocation used a bare suite name unsupported by this runner and
found no tests. An initial no-redraw assertion counted recursively dispatched
reader events rather than the direct notification; the final unit isolates that
boundary with a temporary stub. The first integration attempt reached its overlap
picker but searched for an Apply button; that existing picker labels it Set.
These failed fixture attempts are excluded from the passing evidence. An initial
lint command lacked the separate luacheck source path; the corrected configuration-
aware command is the zero-warning result above.
