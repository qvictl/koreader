# Keyboard PDF zoom without losing page navigation

## Upstream evidence and reproduced defect

[Upstream #14742](https://github.com/koreader/koreader/issues/14742) reports that
Shift + Page Up / Page Down leaves a PDF in page view unable to navigate. Its
log shows keyboard zoom selecting `free`, followed by repeated zero-distance
pans. The report also mentions a configuration-menu crash, without a stack for
that second symptom.

The accepted fork main `30ec400e` retains this path: `onZoom` scales `self.zoom`
and selects `free`. ReaderPaging deliberately computes zero navigation offsets
in that mode, while `free` has no configurable zoom genus. A private, generated
three-page PDF reproduces both the navigation stall and the nil genus using
real ReaderUI/native PDF code. A real keyboard-event emulator control reaches
page 2, zooms out, then remains on page 2 after ordinary page-forward (expected
page 3). We do not claim to have reproduced the reporter's separate crash.

## Narrow fix

Only **ordinary non-reflowed page view** changes:

1. Keep the requested absolute scale using the existing factors (`1.333333`
   for zoom-in and `0.75` for zoom-out).
2. Dispatch the normal `SetZoomMode("manual")` event. This keeps ReaderPaging,
   configurable genus and ReaderKoptListener's normal mode synchronized.
3. Obtain the manual-mode width scale from the existing `getZoom` calculation
   **after** switching modes, so cropping and 90/270-degree rotation are included.
4. Apply and persist the equivalent `kopt_zoom_factor` and manual mode through
   `SetZoomPan`, retaining the existing redraw/cache-cap behavior.

Page/bookmark flipping with `orig_zoom_mode`, and skim with `skim_backup`,
retain the old keyboard free-zoom path. These existing markers identify modes
with a restoration snapshot; keyboard zoom must not persist temporary changes
into the original scroll setting, manual factor or Kopt normal mode. A fit-page
skim that creates no backup changes no state on entry and has no restoration
contract; it follows ordinary page-view semantics. This patch does not introduce
a new global skim lifecycle or change ReaderPaging's restoration protocol.

No global free-zoom navigation rule is changed. Temporary regional/double-tap
free zoom keeps its existing behavior. Continuous view and reflow take the old
keyboard branch: this patch does not force continuous view into page view or
claim to fix those branches' historical free/configuration limitations.
Manual zoom remains relative to each page's width; pages with different geometry
are not promised an identical absolute pixel scale. Existing cache safety limits
can cap extreme zoom, as before.

## Initial reviewed snapshot and historical validation

Accepted base: `30ec400edb1421ddec6837f2f1d8f959290f7593` (main after #82).
Published code/test object: `33012df02affe3f1431a43c1cf64196252450c6f`.
Its tree `d64abf551c342304b12cd4a70d720c2d42c257ff` equals local tested
`f2462c20cdca630dc47b35b48cf1ef48c9276152`. The report-only successor changes no
production or test code. Integration README entries 56 and 57 are both retained.

| Check on the main-82 combination | Result |
|---|---|
| New native unit suite | 16/16 |
| Seventeen related unit suites | 292/292, no exclusions |
| Scenarios 01 / 02 / 09 / 50 / 51 / 53 / 54 / 55 / 56 / 57 | 229/229 checks; applicable budgets pass |
| Scenario 57, fresh-profile repeats | 3 × 18/18 |
| Fresh unit changed-line coverage | 10/10 (100%); passes the 80% PR gate |
| Lua lint / original pixel-size checks / whitespace | Zero warnings/errors/fatals; pass |

Related unit suites: `readerzooming_keyboard`, `readerpaging_nav`, `readerpaging`,
`readerui`, `readerui_lifecycle`, `readerstatus_lifecycle`, `readerlink`,
`readerhighlight_pdf_actions`, `koptinterface`, `koptinterface_background`,
`koptthread`, `uimanager`, `key`, `readtimer`, `docsettings`, `document_registry`
and `vocabbuilder_context`.

The new suite uses native PDF documents, not fake page geometry. It verifies
zoom-out page turning, zoom-in panning, valid configurable genus, no-crop mode,
real Shift-page-key mapping, 90/270-degree conversion, transitions from page,
content, width and manual modes, consecutive zoom operations, normal-mode
tracking and close/reopen persistence. Regional-free and continuous behavior
are compatibility controls. The reflow branch boundary sets the configuration
flag without launching native reflow; it is not reflow-rendering certification.

Scenario 57 uses a private synthetic PDF, real keyboard-event dispatch through
UIManager, native rendering, ordinary forward/back keys, zoomed panning,
bottom configuration-menu paint/dismissal and close/reopen. It does not simulate
hardware key interrupts or certify any particular physical Kindle/desktop.
The fixture uses separate protected menu/reader cleanup and retains private
inputs until process teardown. Units restore PluginLoader state and remove only
owned generated PDFs and their settings after closing their readers.

## Controls and limits

With unchanged actual main-82 production, the same new unit suite passes 5 and
fails 11 assertions; these test propagation/state expectations, not eleven
separate upstream bugs. The unchanged-code emulator fails on the real
page-forward action after zoom-out, with actual 2 versus expected 3. Candidate
production is restored afterward. The earlier main-81 zoom source is byte-for-
byte identical, but final controls above were rerun against main 82 explicitly.

Earlier main-81 combination results (260 units and 204 emulator checks) are
historical, not the final combination totals above. Initial local harness runs
lacked `sample.pdf`/`djvu3spec.djvu` for pre-existing related suites; they were
not counted as product failures or passing suites. The new tests use generated
PDFs. For related suites, existing local fixtures were reused only after their
Git blobs matched pinned test-data commit `c3b5d06e1ae8ea088bd898b0e7f9da3753d0d86c`:
`sample.pdf` = `943ea4746924f6aecb5f402b35012ff08ff0011c` (3,619,757 bytes),
`djvu3spec.djvu` = `f2fdb27fed71d1c998cfb61802745253b16914a0` (484,184 bytes).
The complete selected batch then passed without exclusions.

The later review-driven results are recorded separately below.

Existing authorized native emulator assets were reused, not rebuilt. No live
network service or user book was involved. Whole-repository/release coverage,
physical-device behavior and arbitrary PDF/reflow inputs are unmeasured.
Independent source/log review is separate from runtime execution; exact-head
CI, formal included review and the normal merge gate remain required.


## Review-driven preview isolation

CodeRabbit identified three consequences of letting keyboard zoom persist
manual settings inside a temporary preview: continuous-view configuration could
be reset, normal manual scale overwritten, and skim could replace Kopt's normal
mode. We reproduced these with real native ReaderUI fixtures before changing the
code. Two guards reuse the existing restoration markers described above, rather
than expanding the cross-module preview save/restore protocol.

The unit suite now additionally covers page and bookmark flipping followed by
reopen, manual scale preservation in flipping and skim, normal-mode restoration,
closing while flipping is active, returning to ordinary keyboard zoom, and
explicit no-backup skim semantics. Genus is asserted exactly as `0`; rotated
manual scale is independently checked against the fixture's native height with
cropping disabled. Input's instance-level double-tap state is restored by raw
field value after each case, alongside the previous plugin/resource cleanup.

Scenario 57 adds native flipping with real UIManager key dispatch, continuous
view after reopen, preserved manual factor/scale, and a real skim dialog's
lifecycle. **The skim modal itself consumes page keys**: that one synthetic key
is explicitly sent to ReaderUI, not represented as a physical key reaching the
reader through the modal. This verifies the public reader entry while a real
skim snapshot/widget exists; normal reading and flipping keys still traverse
UIManager. Skim, configuration menu and reader cleanup are independently
protected, and Input state is restored even after scenario failure.

Final-code controls with reviewed production `8ceb4e00`: **17/23 unit cases pass,
6 fail**, precisely exercising the preview-state regressions. The final emulator
control fails when temporary flipping overwrites the continuous-view config.
Preliminary development attempts had incomplete manual/scroll fixture setup,
a mode-warning popup consuming keys, and an incorrect reader module field name;
these were corrected and are excluded from passing results and defect counts.
The guard does not claim to fix all historical preview gestures, modal key
routing, native reflow or physical-device behavior.

Final reviewed-fix code/test object: `f78e977ea622d414ed5689784d74b5f111525464`,
tree `5f37a80ae96a69ed30f33ed45dbe8772bb6df712`, matching local tested
`6695fb279d77fd4f971f9572199ca4993ccf3291`. The subsequent report commit changes
no executable/test code. Validation on this exact code/test tree:

| Final check | Result |
|---|---|
| Expanded native unit suite | 23/23 |
| Same seventeen related unit suites | 299/299, no exclusions |
| Same ten emulator scenarios | 239/239; applicable budgets pass |
| Scenario 57 fresh-profile repeats | 3 × 28/28 |
| Fresh unit changed-line coverage | 11/11 (100%) |
| Original lint / size / whitespace checks | 0 warnings/errors/fatals; pass |

These replace, rather than retroactively reattribute, the initial 16/292/229
and 3 × 18 results above. Independent final source/log inspection found no
remaining actionable issue; formal exact-head CI and review are still required.
