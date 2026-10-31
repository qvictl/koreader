# Partial touch frames: prevent a reader crash

## Source and reproduction

[Upstream issue 16061](https://github.com/koreader/koreader/issues/16061)
reports a Kindle Colorsoft crash when a second touch slot arrives without
coordinates. The same path remains in fork main `3933787fb891befec8b6e2088f9b67db8da5595c`.

`Input` retains a stable table for every touch slot. An early tracking-ID-only
frame used to create a `Contact`; pairing another contact then copied the
incomplete table into `initial_tev`. Moving the valid contact reaches two-finger
pan arithmetic against the nil coordinate. A partial contact could also turn
an ordinary hold into a spurious two-finger hold.

A deterministic native regression matrix reproduces nil arithmetic with either
slot arriving first, either main slot incomplete, and one or both axes absent:
12 errors plus one incorrect hold. With the final expanded regression suite,
the old production file fails 16 cases (13 nil-arithmetic errors and three
assertion failures), while the fixed implementation passes all 66 cases. The real emulator reproduces the same
`Contact:getPath` traceback through `Input:handleTouchEv`, `feedEvent` and the UI
loop. The integration harness catches the UI-action exception and records a
failed scenario; this is not a claimed unhandled process crash in the harness.

## Fix

Only admit a new contact once both coordinates are present. Input still retains
the partial slot, so late coordinates can start a normal contact without losing
the earlier tracking ID. Complete active contacts follow the unchanged path.
Zero coordinates remain valid. No replacement coordinates or gestures are
fabricated, and a never-admitted contact has no timers or buddy references.

This is deliberately narrower than modifying each arithmetic site or assigning
`voidState` to an incomplete contact: void-state motion and some callers still
perform coordinate arithmetic. The admission invariant keeps the incomplete
contact out of every buddy path instead. Existing recovery for coordinate-first,
tracking-ID-later frames remains covered.

## Validation

- Added 19 unit cases for partial slots, both main-slot orders, late/zero
  coordinates, complete frames, timers, hold, same-frame processing order,
  lift-before-coordinate and slot reuse. Updated the old assertion that explicitly
  accepted an incomplete buddy snapshot.
- **146/146** final related native tests: gesture state machine, concurrent
  taps/rotation, Input lifecycle, batching, deadline and protocol handlers.
- Changed-line unit coverage: **7/7, 100%** under the repository's unchanged
  `--mode diff` gate; whole-repository coverage is not measured.
- `40_gesture_missing_coordinates`: **37/37** checks, three fresh runs. Real
  protocol-B frames travel through Input/GestureDetector/UIManager/ReaderUI;
  six malformed-frame sequences still turn exactly one EPUB page each, then
  close/reopen and an ordinary tap remain functional. Uses an isolated Input
  instance and profile, not a replacement native backend.
- Related `16_filemanager_input_lifecycle`: **13/13**, three fresh runs.
- Final combined emulator pass: scenario 02 **13/13**, scenario 03 **10/10**,
  scenario 40 **37/37**; all five English/CJK responsiveness budgets pass.
- Independent local review: no blocking finding; 76 tests (including five
  extra ordering cases subsequently incorporated), and three more scenario-40
  runs at 37/37.
- Merged actual current main `44511631`, retaining README scenarios 38/39/42/44
  and the accepted sidecar/base helper and collection/XMNote fixes. All 146 related
  tests pass with that production combination. Scenarios 02/03/16/40 pass three
  fresh runs each, **219/219 checks and 15/15 responsiveness budgets**. On the
  final main tree, scenarios 02/03/16/40/45 pass again: **99/99 checks**, all five
  responsiveness budgets, including the newly merged XMNote compatibility case.
- Lua lint and whitespace checks pass.

All **158 front unit suites** were also attempted in separate Busted processes
against the final combined source: **155 suites pass, with 2,235 successful test
cases** reported by Busted. Three suites remain blocked by the unchanged host
environment: GetText setup needs unavailable `msgfmt`, one NetworkMgr assertion
requires prohibited `getifaddrs`, and four live-Internet translator cases fail DNS
resolution. These restrictions were not bypassed. This is not a clean full-suite
claim; exact-head remote CI and formal review remain required.

## Runtime and scope

All 500 core production Lua overlays were verified byte-for-byte against this
candidate; all 92 base FFI Lua files also match the actually merged base
`d1b27196eac53e8c810c63762ed6bfb40f226382`, inherited from main. Native libraries
are reused from the existing fork emulator artifact; that base update changes
only Lua, not native code. The separate held base PR 36 is not included.
SDL3 is the existing isolated local 3.4.18 build. This is current-source Lua
validation with reused native binaries, not a fresh Kindle/native build or
physical touchscreen test. It does not diagnose the driver or the separate
multi-input-FD slot-identity issue.

No upstream communication, release, device installation or branch-protection
change is part of this fix. Publication and included public-fork review may
proceed through the existing gates; no paid add-on activation is authorized.
