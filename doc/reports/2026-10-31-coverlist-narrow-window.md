# Cover-list cached rows in narrow desktop windows

## Evidence and scope

Upstream [issue 13655](https://github.com/koreader/koreader/issues/13655)
reports an AppImage crash at 228 × 816 when drawing cached book information.
The current cover-list row subtracts a square cover column, optional right-side
information and padding from its width. With the valid four-items-per-page
preference, the remaining title width can be nonpositive; native XText rejects
that width in `TextBoxWidget:makeLine`.

This was reproduced on the fork's unchanged production with a private EPUB,
a real custom PNG cover, native extraction/cache and actual list painting at
228 × 816 / 96 DPI. The stack reaches `ListMenuItem:update` through
`CoverMenu:updateItems`, not a simulated exception. The optional columns are
not indispensable: for this case only, discard their widgets and use the row
width for title/authors with bounded side padding. Ordinary positive-width
layouts keep their original geometry and cover extraction sizes.

The cover setting is not changed. Effective displayed-cover flags drive the
layout, focus underline and description marker, and are committed together
with the new widget. A temporary cache miss that retains the old subtree also
retains its flags. The existing owning image subtree is freed once; its decoded
buffer is neither reused nor freed again. Other rows' menu-level image hints
are preserved. Widening restores the normal image and metadata columns.

This is not a global text-width clamp, a window-size restriction or a new image
rescaling policy. It does not change directory/uncached layout arithmetic,
which was exercised at the reported target width but is not claimed safe for
arbitrary impossible dimensions. Native Linux SDL validation is not physical
e-reader or macOS validation.

## Validation

Accepted base: `da47c289807e4a499f3a47427bdfc2831f352312` (base gitlink
`fcdb4d77faa04cc21f58cfb952ca2f5a25ce5577`). The private runtime contains the
accepted proxy module, SHA-256
`d0e02b15f926cfff7989dbf3f6ed0d26a3f939f9fe1d40f9f3d2520e788da579`;
existing authorized native assets were reused, not claimed to be rebuilt.

| Reachable tested snapshot | Evidence |
|---|---|
| `4b463ba90cf6ee9c1ce6461d7df918e0a23ff471`, tree `a25a4d5dcbb935c880552745f63e34fba5a119f8` | 263/263 focused unit cases in 16 separate processes; 172/172 checks across integration scenarios 01/02/09/16/18/43/46/49/50/51; applicable response budgets pass; fresh changed-line unit coverage 19/19 (100%) |
| `dc323c7f194db1c6c4e1536d743d0257f3c26a5f`, tree `057aed4d808ec6bcf8ea55592a4160d22cbe989b` | Test-only History extension and README update; final scenario 51 passes 22/22 with default startup and three fresh 228 × 816 / 96 DPI profiles, 22/22 each; production and unit-test bytes are unchanged |
| `6136de6788c38a6359fd702e790ff3e7fab18d85`, tree `ba43d249c3aad3fe2540a57ac1d7a95ba2c40e05` | Unit-fixture naming only, after the initial CI pixel-style warning; 263/263 focused unit cases rerun, final scenario 51 rerun 22/22 at default startup, fresh changed-line coverage 19/19; production and integration source unchanged |

The report-only successor does not change source or tests. The 172-check
combination predates the four additional History checks; it is not presented
as a rerun of the entire combination on the final test-only snapshot. This is
selected validation, not a whole-repository or release-suite pass. Final Lua
lint reports zero warnings/errors and whitespace checks pass. The initial CI
passed its native/base/frontend tests and coverage, but its separate
unscaled-size style check flagged intentional literal pixel fixtures. Named
native-pixel constants now preserve those exact test dimensions and assertions;
the unchanged repository size-check expressions and Lua lint both pass locally.
No lint rule, exclusion or production dimension was changed. Independent
static/log/image review found no remaining blocker; that reviewer did not
independently execute the runtime.

Selected unit suites were run through `spec/runtests -c --busted front` in
separate emulator processes. Integration command (with the selected build):

```sh
tools/run_integration_tests.sh --kodir <built-emulator> \
  --output <private-output> 01_ 02_ 09_ 16_ 18_ 43_ 46_ 49_ 50_ 51_
EMULATE_READER_W=228 EMULATE_READER_H=816 EMULATE_READER_DPI=96 \
  tools/run_integration_tests.sh --kodir <built-emulator> \
  --output <fresh-private-output> --repeat 3 51_
```

- New unit suite: 11 cases using native TextBoxWidget/ImageWidget/Blitbuffer;
  cached real/fake/ignored covers, text-only oversized metadata, hidden optional
  fields, mirrored layout/description/focus, normal geometry, repeated
  wide–narrow–wide updates, image-owner release counts, retained cache-miss
  subtree state and target-width directory/uncached paths.
- Unchanged production with the new suite: 1 pass, 3 assertions fail because
  effective-cover state is absent, and 7 errors from the actual nonpositive
  XText width. These results are not all described as seven separate bugs.
- Scenario 51 uses the real SDL3 `SDL_SetWindowSize` API, actual native cover
  extraction and painting, repeated narrowing/widening and real reader page
  turns, close and reopening. No layout, image, document or filesystem mocks.
  The final extension also opens History through its real manager and checks
  the cached row/date-column fallback and normal close. It writes private PNG
  screenshots; visual inspection confirms readable
  fallback text and restored wide-layout image/metadata.
- 228 × 816 / 96 DPI startup and the default 1072 × 1448 / 300 DPI startup were
  both exercised. Startup font metrics are cached; the scenario first paints
  228 × 816, then also uses 228 × 1200 to guarantee a nonpositive column budget
  under the default startup metrics. Widening uses 800 × 1200. These are
  distinct configurations, not claims that every 228-pixel row needs fallback.
- Test development failures are excluded from pass evidence: the first harness
  omitted the normal FileChooser class item-count setting, and another assumed
  identical cached font metrics after resize. A negative-control attempt timed
  out waiting 15 seconds for native metadata; the next unchanged-production
  attempt reached the exact XText stack. The final extraction wait is 30 seconds
  without weakening metadata, layout or reader assertions.
- Private input files are retained through process teardown, including failure paths.
  Widget/worker cleanup, collection state, display preferences and native
  window restoration are handled independently; no user library is accessed.

Exact-head CI, included CodeRabbit review and the normal merge gate are still
required. No paid add-ons or upstream repository writes are involved.
