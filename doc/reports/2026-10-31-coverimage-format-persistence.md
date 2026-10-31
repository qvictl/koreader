# Cover image: retain the color-format selection

## Evidence and impact

[Upstream #13674](https://github.com/koreader/koreader/issues/13674) reports that
PocketBook's “BMP file format (color)” checkbox becomes unchecked after restart.
The same comparison is still present at fork main `624275dc`.

`CoverImage:init()` reads `cover_image_grayscale` with `isTrue()`, producing a
boolean. Color BMP, JPG and PNG menu entries omit their optional `grayscale`
argument, leaving it `nil`. After reinitialization, their `checked_func` compares
`false == nil` and reports unchecked. Selecting the same persisted color format
also compares `false` to `nil` and needlessly regenerates an enabled cover.

**This is selection-state inconsistency, not demonstrated loss of the image
format.** The old production code passes the real RGB/BMP export assertions in the
negative integration run before failing the checkmark assertion on the new reader
instance. The saved format name and actual colored output remain intact.

## Minimal change

Normalize the optional argument once in `menuEntryFormat()` using
`grayscale = grayscale == true`, matching `init()`'s existing `isTrue()` semantics.
This is one executable production line plus a comment. All current callers omit
the argument for color, or pass `true` for grayscale BMP.

The change does not alter encoder implementations, the selected format name,
automatic filename-based format choice, PocketBook logo policy, cover path rules,
or native image extraction. Color/grayscale selection becomes mutually exclusive
and consistent before and after reinitialization; unchanged color reselection no
longer requests unnecessary regeneration.

## Validation

Reachable production/test commit `fe86eb3a7a84c2cf34c547ae63839350bcc90a4c`,
tree `822dda76f5df267440eabbf42353c57d182771e4`, is based on accepted main
`624275dc`. Its report-only successor does not change executable/test bytes.

| Check | Result |
|---|---|
| New unit suite | 6/6; unchanged production fails all 6 after harness correction |
| Thirteen focused unit suites | 216/216 |
| Real emulator scenarios 01 / 09 / 48 / 50 / 51 / 53 | 114/114 checks; applicable budgets pass |
| Scenario 53, final three fresh-profile repeats | 3 × 25/25 |
| Fresh changed-line unit coverage | 1/1 (100%); not whole-repository coverage |
| Lua lint / original pixel-size checks / whitespace | Pass; zero Lua warnings/errors; no rule changes |

The unit suites are `coverimage_format`, `coverimage_bootlogo`,
`coverlist_narrow`, `covermenu_lifecycle`, `imagewidget`, `textboxwidget`,
`readerui`, `readerui_lifecycle`, `readerstatus_lifecycle`, `filemanager_ops`,
`menu_table_screen_color`, `luasettings` and `uimanager`.

The new unit cases serialize and reopen actual private LuaSettings files, testing
all three color formats, absent legacy grayscale settings, grayscale/color
exclusivity and regeneration counts. Only the image-generation callback is a
counter in these unit cases. The actual global settings object is restored before
cleanup, and fixture ownership is established before removing any test file.
An initial harness shadowed the global in Busted's environment; those preliminary
runs are not used as product evidence. The corrected unchanged-code control fails
on the real persisted-state comparison and redundant regeneration.

Scenario 53 drives real TouchMenu input and checks the instantiated CheckMark
widgets. It writes a synthetic RGB PNG, opens a native EPUB with that custom
cover, exports actual color and grayscale BMPs, checks 24/8-bit BMP headers and
native decoded channel values, flushes/reads settings, closes/reopens ReaderUI,
changes modes again, turns a page and verifies reading progress. The unchanged
production run passes 9 checks then fails exactly at “color remains checked on the
new reader instance.” No image writer, filesystem or device SDK is mocked.

The scenario enables color through CanvasContext's normal API and restores that
state and saved preferences before independently protected menu/reader cleanup.
Native image buffers are freed before assertions. PNG fixture writing checks both
Lua-call success and the writer's returned status. Private inputs remain available
through any background-worker/process teardown.

An independent reviewer checked source, ownership, cleanup and recorded results;
this was static/log review, not an independent runtime rerun. Exact-head CI and
normal included review remain required. These are Linux-emulator results using
existing authorized native assets, not physical PocketBook/macOS verification or
a freshly rebuilt native/release-suite pass.
