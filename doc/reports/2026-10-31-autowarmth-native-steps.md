# AutoWarmth: schedule reachable native warmth levels

## Upstream evidence and provenance

[Issue #15942](https://github.com/koreader/koreader/issues/15942) reports coarse
scheduled warmth changes on a Kindle with 24 native steps. At accepted fork main
`6444a3ce`, interpolation retains only percentages for which
`frac(percent * native_max / 100) == 0`. For a 24-step driver this produces only
five entries for 100% to 0%, although the real generic conversion can reach 25
levels including zero. The reported 90% to 20% range similarly retains only
`90, 75, 50, 25, 20` rather than visiting native levels 22 through 5.

The native-level comparison is adapted from Alex's
[upstream PR #15943](https://github.com/koreader/koreader/pull/15943), commit
`459bcc346d2e374593b096e45050b4700331894a`. The local cherry-pick preserved its
author and provenance; the published port commit credits the original author.
The following compatibility changes and expanded tests are fork additions.

## Why this is not an unmodified cherry-pick

The upstream comparison is used only when natural light exists, warmth control
is enabled, and both segment endpoints are ordinary percentages. It calls
`Powerd:toNativeWarmth()` to keep a transition to a new level, leaving the final
level to its configured endpoint instead of inserting an earlier duplicate.
Configured anchors and their times are retained, including equal-level anchors.

Other segments keep the existing fractional filter, clamp and timing policy:

- A Kindle driver can declare a 24-step scale even when the device exposes no
  natural light. Applying that hidden scale to night-mode-only scheduling changes
  the first intermediate event of `1100 -> 0` from 99% at 36 seconds to 97% at
  108 seconds. The old 100-percent scheduling resolution is preserved there.
- Night mode is encoded by adding 1000 to a percentage. For the valid anchor
  `1090`, production `setWarmth()` applies 90%, or native level 22. The existing
  interpolation clamps that encoded value to 100; blindly retaining newly
  reachable native levels would then introduce a reverse step to level 23.
  The inverse ramp can overshoot before its flagged endpoint. Flagged segments
  retain their old behavior rather than redesigning night-mode interpolation.
- With warmth control disabled, both ordinary and flagged endpoints retain the
  existing night-event sequence and timing; no synthetic hardware writes occur.

This fixes ordinary warmth ramps, **not all flagged warmth ramps or night-mode
interpolation policy**. It does not change device drivers, suspend/resume logic,
solar calculations or hardware commands. Current generic conversion is the
reference; lower-level device mappings and physical warmth have not been tested.
For drivers with more than 100 native steps, the public integer-percent input
grid still limits the reachable schedule to at most 101 values, not every level
of a 256-level device.

## Validation

Production/test commit `d08f92ab0c64379f8c8600f9c81230dcf0db0b59`, tree
`d7977a779ac58b83967b2208d562904a44c0c3e6`, matches the tested local tree based on
main `6444a3ce`. The report-only successor does not change production or tests.

| Check | Result |
|---|---|
| New AutoWarmth unit suite | 19/19 |
| Seventeen focused unit suites | 186/186, no exclusions |
| Emulator scenarios 01 / 09 / 47 / 48 / 50 / 51 / 53 / 54 | 185/185 checks; applicable budgets pass |
| Scenario 54, three final fresh-profile repeats | 3 × 42/42 |
| Fresh changed-line unit coverage | 10/10 (100%); not whole-repository coverage |
| Lua lint / original pixel-size checks / whitespace | Pass, zero Lua warnings/errors; no rule changes |

Related suites are `autowarmth`, `frontlight`, `dispatcher`, `uimanager`,
`menu_table_screen_color`, `readerui`, `readerui_lifecycle`,
`readerstatus_lifecycle`, `coverimage_format`, `coverimage_bootlogo`,
`coverlist_narrow`, `covermenu_lifecycle`, `textboxwidget`, `imagewidget`,
`luasettings`, `datetime` and `optmath`.

The 19 cases exercise ascending/descending full and partial ranges, 10/24/100-step
drivers, the 255-step input-resolution limit, constant/equal-level anchors,
zero/reversed duration, no-natural-light scheduling, flagged endpoints and both
forms of warmth-disabled control. They use the actual generic conversion and,
for flagged/night-only cases, actual `setWarmth()` masking. Sun/time, queue and
hardware boundaries are synthetic in unit tests and restored afterward.

Two controls distinguish the original bug from port regressions:

- Unchanged main passes 14/19 and fails five native-range/resolution cases;
  scenario 54 fails at 25 expected scheduled entries versus 5 actual entries.
- The clean upstream port on the same main passes 14/19 but fails a different
  five cases: no-natural-light timing, both flagged directions and both
  warmth-disabled variants. Its scenario 54 passes the ordinary ramp, then
  fails the flagged-policy assertion: 5 expected entries versus 20 actual.

Scenario 54 taps the real activation menu, verifies the normal saved preference,
dispatches actual callbacks through UIManager's next-tick queue, observes all
25 native writes/events, checks unchanged anchor times, cancels the private
schedule through production suspend handling, and checks the flagged 90% ramp.
Solar time is advanced synthetically to each generated time: this is not a
one-hour wall-clock or physical-device measurement. The original emulator power
driver, time functions and preferences are restored before a native EPUB is
opened, turned, closed and reopened to verify reading progress. Private input
files remain available through background-worker/process teardown.

Cleanup cancels the private plugin's function callbacks before restoring its
boundaries; reader and widget cleanup are independently protected and report
errors together. Initial harness attempts used an EPUB-inappropriate paging
field and then an obsolete FileManager identity after reader closure. Both were
corrected; those failed attempts are not included in passing evidence.

Independent source/log review found no remaining blocker; it was not an
independent runtime rerun. Exact-head CI and the normal included review remain
required. These are Linux-emulator results with existing authorized native
assets, not a new native/release build or physical Kindle/PocketBook verification.
