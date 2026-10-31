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

Only **non-reflowed page view** changes:

1. Keep the requested absolute scale using the existing factors (`1.333333`
   for zoom-in and `0.75` for zoom-out).
2. Dispatch the normal `SetZoomMode("manual")` event. This keeps ReaderPaging,
   configurable genus and ReaderKoptListener's normal mode synchronized.
3. Obtain the manual-mode width scale from the existing `getZoom` calculation
   **after** switching modes, so cropping and 90/270-degree rotation are included.
4. Apply and persist the equivalent `kopt_zoom_factor` and manual mode through
   `SetZoomPan`, retaining the existing redraw/cache-cap behavior.

No global free-zoom navigation rule is changed. Temporary regional/double-tap
free zoom keeps its existing behavior. Continuous view and reflow take the old
keyboard branch: this patch does not force continuous view into page view or
claim to fix those branches' historical free/configuration limitations.
Manual zoom remains relative to each page's width; pages with different geometry
are not promised an identical absolute pixel scale. Existing cache safety limits
can cap extreme zoom, as before.

## Exact provenance and validation

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

Existing authorized native emulator assets were reused, not rebuilt. No live
network service or user book was involved. Whole-repository/release coverage,
physical-device behavior and arbitrary PDF/reflow inputs are unmeasured.
Independent source/log review is separate from runtime execution; exact-head
CI, formal included review and the normal merge gate remain required.
