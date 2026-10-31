# Dispatcher absolute warmth picker: native bounds

## Evidence and scope

This is a separate follow-on to Android scale PR #96, not an assertion that its
three production changes also fixed the action picker. Upstream
[PR #13344](https://github.com/koreader/koreader/pull/13344), merged as
`8def50f2187ff32649dd7ecec786253d60c9937b`, established native device levels
for absolute warmth actions. Current `Dispatcher:execute` sends the saved scalar
to `SetFlWarmth` unchanged; the listener converts that native value to the public
percentage API. The incremental action descriptors already use native warmth maxima.

The absolute picker alone still used `min=1` and the **brightness** maximum.
With brightness max 100 and warmth max 255, the normal picker cannot choose zero
or levels above 100. With warmth max 24, it offers values beyond that native range.
These are synthetic architecture/real menu reproductions, not new physical-device
observations or a claim to reproduce every symptom of upstream #16027.

The production change is one action-descriptor line: use `fl_warmth_min` and
`fl_warmth_max`. Do not change Dispatcher execution, saved value format, defaults
elsewhere, incremental steps, brightness or generic rounding. Existing stored
values, including zero or legacy out-of-range values, are not migrated or changed
merely by opening the picker; existing consumer behavior remains responsible for
such old values. This patch does not promise every native level survives the
public percentage conversion, or redesign nonzero-minimum scaling.

## Frozen candidate and tests

Local code `31efc733bb3f2a58dc02055e4be696a53800ba9f` and published code object
`dc0915b06fb08c7eaf32d855150f7a7d08a06157` have identical tree
`bdf88c53d985bcc5dfc2074ca49e8d42737a5eee`. This snapshot includes the final
#96 candidate, based on accepted #95 `aab4147b`; #96 acceptance and subsequent
main synchronization are tracked separately before this candidate is published.

| Check | Result |
|---|---:|
| New focused units | 17/17 |
| Related units, 17 nonempty suites | 361/361 |
| Related integration scenarios, 18 runs | 944/944 |
| Scenario 70 in three fresh profiles | 3 x 112/112 |
| Fresh changed-executable-line unit coverage | 1/1 |
| Lint / size / whitespace | zero warnings; pass |

The unit selection includes Dispatcher, its new picker suite, Android warmth,
autowarmth, frontlight, generic/Kindle device, gesture/multitouch/range, buttons,
menus, ReaderUI lifecycle, readtimer, OPDS credentials, metadata preference and
style-tweak notifications. This is not a full-repository test or coverage claim;
whole-repository coverage metrics are unmeasured/null.

The 17 focused units use private Dispatcher instances with synthetic power
ranges 10/24/100/255 and a synthetic picker boundary. They exercise real menu
construction, saving and event dispatch, including zero/defaults, maximum,
nonzero minimum, saved zero, no implicit legacy-value migration, unchanged
brightness/incremental descriptors and devices without natural light.

Scenario 70 uses actual painted TouchMenu, SpinWidget and numeric InputDialog.
For synthetic native ranges 255 and 24, it taps the real action entry, checks
default/min/max, enters values via the real numeric dialog, applies and cancels,
reopens repeatedly, and saves/reloads the action scalar through a private
LuaSettings file. Real Dispatcher events pass through the real listener and
Generic power conversion to a synthetic native setter. This is not the full
Profiles plugin persistence UI, Android JNI or physical light hardware.

Cleanup independently closes the owned input/picker/menu/event receiver, restores
power/capabilities/class scale/notification state, and removes only the asserted-
absent private settings file and its backup. The repeated-run profiles contain
neither file afterward. No reader, book copy or cover worker is involved.
The original nonnil FileManager is checked as the final topmost widget.

## Negative controls and independent review

Replacing only Dispatcher with actual accepted-main #95 code gives **5 passing
and 12 failing** focused cases. The unchanged 100-level maximum, compatibility
and unavailable-device controls pass. Scenario 70 fails at the real picker
minimum: expected zero, got one. The candidate source was restored and matched
byte-for-byte afterward. This is a precise picker-domain regression, not 12
independent hardware bugs.

An independent reviewer read the production/fixtures and ran **17/17 units plus
112/112 integration checks** in a separate runtime, checking source hashes before
and after. No actionable finding remained. This was not an independent complete
361-unit/944-check combination, negative run or native rebuild.

Linux emulator native assets were reused, with exact generated HTTP Lua from the
accepted base `d59a3cb1` (the 308 patch changed Lua, not native C/FFI). No firmware,
Android package, physical reader, remote service or upstream repository was
modified. A first local coverage-report invocation lacked its LuaCov module path;
the corrected invocation produced the fresh 1/1 result above, not a production
failure. Normal draft-first publication, exact-head CI, included review and
merge gates remain required; no paid add-on or gate bypass.
