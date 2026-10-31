# Android warmth scale boundaries

## Evidence and scope

[Upstream issue 16027](https://github.com/koreader/koreader/issues/16027)
reports an invalid initial warmth and gestures stopping near native level 99 on
a 255-level Boox device. This patch reproduces the corresponding Lua defects
with synthetic integer JNI values; it does not certify the reported hardware.

The Android launcher is pinned at `e0c3c861b043966a8d845392f10d64da095f99bc`:

- [android.lua](https://github.com/koreader/android-luajit-launcher/blob/e0c3c861b043966a8d845392f10d64da095f99bc/assets/android.lua)
  reads `getScreenWarmth` as a JNI integer and writes `setScreenWarmth` as an integer.
- [MainActivity](https://github.com/koreader/android-luajit-launcher/blob/e0c3c861b043966a8d845392f10d64da095f99bc/app/src/main/java/org/koreader/launcher/MainActivity.kt)
  forwards those values unchanged to the light controller.
- The pinned [Onyx SDK controller](https://github.com/koreader/android-luajit-launcher/blob/e0c3c861b043966a8d845392f10d64da095f99bc/app/src/main/java/org/koreader/launcher/device/lights/OnyxSdkLightsController.kt)
  and [ADB controller](https://github.com/koreader/android-luajit-launcher/blob/e0c3c861b043966a8d845392f10d64da095f99bc/app/src/main/java/org/koreader/launcher/device/lights/OnyxAdbLightsController.kt)
  return raw native levels and validate writes against their native maximum.
  These are source-contract checks, not execution of Android/firmware code.

The generic power driver's public warmth and cached `fl_warmth` are percentages.
Three boundaries currently disagree with that contract:

1. Android reads multiply a raw native value by the native range. At native 128
   with maximum 255 this produces 32640 instead of public 50 percent.
2. Gesture actions calculate a native target, but `onSetFlWarmth` clamps it at
   100 before converting it to a percentage. A 255-level target becomes 39
   percent and then native 99. [Upstream PR 13344](https://github.com/koreader/koreader/pull/13344)
   explicitly established native units for these actions; reverting that
   contract would break small-range devices.
3. The standalone-warmth light-on path divides the public cache by the native
   range. Restoring public 80 percent on a 255-level fixture writes zero rather
   than native 204.

The fix uses the existing `fromNativeWarmth` for Android reads and
`toNativeWarmth` for standalone restore, and clamps event values to the driver's
native minimum/maximum. The unused `warm_diff` field is removed. No launcher,
firmware, brightness scaling, saved-setting format or generic rounding changes.

## Initial validation and attribution

Base: actual accepted main #93 `406307dfe9346db2d9f39199cdc822c900d8d9f4`.
Local code `759e4e6be4390fe0f7fea1967b262438ef2375e4` and published code
`9381bec961cdc590575b760320e668cbcfc0a0ba` have identical tree
`ed98063c9e6e6d565c43343d3e316399af10d47a`. This report is a documentation-only
successor; executable and test evidence belongs to that code tree.

| Check | Result |
|---|---|
| New `android_warmth_spec.lua` | 17/17 |
| Related selected unit suites | 279/279 in 14 suites |
| Real emulator combination | 670/670 in 14 scenarios |
| Fresh scenario 69 repetitions | 3 x 25/25 |
| Fresh changed-executable-line unit coverage | 6/6, 100%; whole-repository coverage unmeasured |
| Candidate Lua lint | 0 warnings/errors/fatals |
| Original unscaled-size expressions and whitespace check | pass |
| Exact-main unit negative control | 6 pass / 11 fail |
| Exact-main emulator negative control | initial state expected 50, got 32640 |

The selected suites cover Android warmth, AutoWarmth, frontlight, device,
Kindle device, dispatcher, gesture detection/multitouch/ranges, buttons, menu
sorting, reader lifecycle, read timer and OPDS credentials. All are nonempty;
this is not a full-repository unit run. Integration includes scenarios
01/02/16/47/50/54/55/57/59/62/64/65/66/69; applicable budgets pass.

The new tests use real generic/Android power driver construction and conversion,
mocked integer JNI, native maxima 10/24/100/255, stored-setting initialization,
read-only state queries, no-natural-light and standalone/non-standalone controls.
The initial scenario 69 paints and taps the actual frontlight Min/Max/Toggle widgets,
closes/reopens them, dispatches synthetic gesture-action events through
UIManager, then restores the emulator and opens/turns a real EPUB. It does not
exercise physical touch recognition or the Android native light dialog.
Module/capability/power/settings boundaries are restored even on failure;
widget and reader cleanup are independent. This initial version retained an
owned reader input; the review-driven revision below removes that extra smoke test.

An independent reviewer read the production/tests and reran 17 units plus
25 integration checks in an isolated native runtime, verifying all four final
source/test files byte-for-byte. No actionable finding remained. This was not
an independent full combination, negative-control run or native rebuild.

Two initial development invocations had fixture syntax errors; another used a
Busted-local setting instead of `_G.G_reader_settings`, making the startup
case invalid. Those runs are excluded. The final fixture uses a private settings
object and the final positive/negative controls were rerun. Negative-control
runtime files were restored and compared with the candidate afterward.

## Limits and unchanged behavior

- Linux emulator native assets were reused. No Android package, JNI/Java binary,
  firmware or physical Boox was built or tested, and no hardware light was changed.
- Dispatcher absolute-action menu metadata still uses its existing brightness
  range; this patch fixes the native event consumer and gestures, not that picker.
- Android native-dialog Cancel can still short-circuit when its cached value has
  not changed. The read conversion applies to dialog acceptance, but no complete
  native-dialog lifecycle fix is claimed.
- Generic percentage rounding still limits resolution above 100 native levels;
  this is not an affine/nonzero-minimum range redesign or an assertion that every
  hardware level is reachable. The tested endpoints and native conversions are.
- Both pinned Onyx controllers report non-standalone warmth. Standalone restore
  is a synthetic check of the existing shared Android branch, not a claim that
  those Boox controllers use it.

Normal exact-head CI, included review and merge gates remain separate. No
upstream write, version bump, release, paid review add-on or gate bypass.

## Accepted-main #94 synchronization

While this PR was still draft, accepted main advanced to metadata-preference
fix #94 `dc94b7d6a966c53ee6a52d43f97784f641a2042b`. A normal two-parent merge
preserves both adjacent README rows 67 and 69; there is no production conflict.
Local combination `55578420135deba5e85787ac2bd222241ec27d10` and published
combination `184778a202beedf1252a55d3c5839ccd8e2931c6` have identical tree
`225f2876119fb22654747de6d22ffcebebe748d0`.

The two warmth production files, its unit suite and scenario 69 are unchanged
from the original code tree. The synchronized runtime passed **316/316 in 15
nonempty unit suites** and **776/776 in 15 integration scenarios**, adding the
37-case metadata-preference suite and scenario 67's 106 checks. Applicable
budgets pass. Original negative controls, three repetitions, fresh coverage
and independent 17+25 retain their original snapshot attribution.

The original draft head `23cc602c` passed CI 41220837586; the synchronized
report-only successor still requires its own exact-head CI and formal review.

## Review-driven test artifact correction

CodeRabbit identified the retained EPUB copy in the scenario's final, unrelated
reading smoke test as a test-artifact cleanup issue. Instead of introducing
file deletion while a cover worker might still use the input, remove that smoke
test and do not create the unnecessary copy. This is not an assertion that
closing ReaderUI proves every background worker has stopped.

All warmth assertions remain: initial scale, native display, painted Min/Max,
event-driven increase/decrease, standalone off/on, repeated widget close/reopen
and restoration of the original emulator. The final check repaints and verifies
that FileManager is displayed; no native EPUB reading is claimed for the revised
scenario. It creates no temporary file or directory, and no cleanup worker or
new hardware/mock boundary is introduced. README now reflects this narrower scope.

Test-only local code `99f4c4aca62e6ac8ba6ca34044af267bc5bb3fc8` and published code
`6bf134547afe7a5f3e51ab63f5f15d4aaff521f6` have identical tree
`868a216d87a2fd263c93cecf71829e392da313f7`. Both production files and the 17-case
unit suite are unchanged. The final selection passes **316/316 units in 15
suites**, **775/775 checks in 15 integration scenarios**, and **3 x 24/24** fresh
scenario-69 repetitions. The three profile directories contain no scenario-owned
`it-android-warmth` directory. Lint is zero, size and whitespace checks pass.

The original 6/6 coverage and negative controls still belong to their stated
unchanged production/unit snapshot. Earlier 25-check scenario evidence and the
initial independent 17+25 result remain historical, not final-scenario claims.
The independent reviewer separately reran the final scenario: **24/24**, with
matching source and no scenario-owned directory left behind. The unchanged unit
suite was not independently rerun for this test-only revision.
The final revision requires normal exact-head CI and review acceptance; the
author does not manually resolve the review thread or bypass the gate.
