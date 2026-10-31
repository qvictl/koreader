# Terminal: keep received output out of keyboard input methods

## Evidence and scope

Upstream [#11097](https://github.com/koreader/koreader/issues/11097) records a
Chinese-keyboard stack overflow through `interpretAnsiSeq`, an IME wrapper,
`addChars`, `strike_callback`, transmit and refresh. The related
[#9678](https://github.com/koreader/koreader/issues/9678) reports the same class of
failure with other composing layouts. Current source still sends received text
through instance methods that the keyboard replaces; those wrappers do not
preserve the terminal's `skip_callback` argument.

The isolated baseline uses the real TermInputText widget and actual English,
Chinese pinyin/stroke, Japanese, Korean and Vietnamese keyboard wrappers.
Received synthetic `safe-output# ` is retransmitted by all five IME layouts;
English is the passing control. No shell, PTY, command or external service is
started. A bounded callback-only echo control demonstrates recursion without
allowing an actual stack overflow or executing the received bytes.

## Narrow change

Six parser call sites use the TermInputText class implementation instead of the
keyboard-wrapped instance method:

- Printable received text calls `TermInputText.addChars` with both existing skip
  flags, retaining the final parser redraw and debug guard.
- Received backspace and VT52/CSI left/right cursor operations call the original
  terminal methods with `skip_callback=true`.

User keyboard methods are still wrapped. The initial routing fix changed no
keyboard implementation. The review-driven follow-ups below add narrow, reversible external-cursor
notifications for stateful layouts; no shared method-wrapper helper, complete IME
state machine or temporary global callback suppression is introduced. The intentional VT52 identification reply remains
an outgoing response. Other parser operations have no overlap with the inspected
keyboard wrappers and are unchanged.

This is **not** a general terminal/IME composition rewrite or an ANSI/UTF-8 stream
parser certification. Existing control-C callback handling outside the receive
parser, arbitrary partial escape/UTF-8 sequences, complete interactive editing,
shell supervision and hardware behavior are not covered or claimed fixed.

## Tests

The initial `terminal_ime_output_spec.lua` has 24 cases covering literal UTF-8 output for six
layouts, received backspace/VT52/CSI cursor movement, user input and cursor keys,
bounded echo recursion, intentional identification, Japanese composing-key state,
Chinese candidate preservation, CRLF control parity and layout reinstallation.
Stateful generic/Hangul modules and settings are private to each case; unwrap and
free have separate protected cleanup before restoration.

Scenario **59** uses real InputDialog and VirtualKeyboard widgets, painted-key
input, native text rendering, receive-parser calls, live layout replacement and
repeated close/reopen to a usable FileManager. Only incoming text and outgoing
byte capture are synthetic. It never invokes the Terminal backend. Its final
child-PID subset check means no newly live child remains at that boundary, not
that a snapshot proves every process event. Existing cover workers may finish.

## Validation on actual accepted main-83

Base: `0531bd8ad57d42b69787a0b1ae0052f6296b5ab8`.
Published code object `abc3c8fea133403743ab59888c088ab98db10075` has tree
`70912c8b27b8aa481223ba47ac333c583e987d66`, identical to local tested code
`58cc3cb4330188874e3286a437780f6b870229d0`. The report-only successor changes no
production or test code. Later-main validation is reported separately if needed.

- **24/24** focused units; **267/267 across 17 selected suites**: terminal IME,
  inputtext, input, input batching, input instance lifecycle, input wait deadline,
  external keyboard event map/layout, input container, util/findfiles,
  ReaderUI lifecycle/password cancel, reader-status lifecycle, keyboard PDF zoom,
  Dispatcher and Button. No selected case is filtered out.
- **249/249** checks across ten emulator scenarios: 01/02/16/46/50/53/55/56/57/59;
  all applicable budgets pass. Scenario 59 repeats **3 × 57/57** in fresh profiles.
- Fresh changed-line unit coverage **6/6 (100%)**. This is not whole-repository
  or release coverage. Configuration-aware lint reports zero warnings/errors;
  original size and whitespace checks pass.
- Actual-main control with the final unit cases: **12 pass / 12 fail**. These are
  multiple boundaries of the output-routing defect, not 12 separate device bugs.
  Real scenario 59 also fails when received Chinese-layout output reaches the
  transmit callback; the candidate is restored and compared afterward.

Three development fixture problems were corrected and excluded from passing
claims: a combined cursor sequence exposed existing within-buffer cursor-position
behavior, the emulator's physical-keyboard default initially hid the virtual
keyboard, and an exact child-count assertion wrongly rejected an existing cover
worker finishing. Final controls use separately delivered cursor sequences,
explicitly visible virtual keyboards and a final PID subset check respectively;
no production workaround or broadened ANSI fix was introduced for these.

Native emulator assets are reused rather than rebuilt, with the existing official
SDL3 dependency. These host results do not establish physical Kindle performance,
actual shell interaction, or a fully rebuilt release. Independent review is
source/log inspection for this historical revision; the later hook revision also
has an independent isolated runtime run, described below. Exact-head CI and
formal review remain required before any merge.

## Initial accepted main-84 combination

Accepted base is now `6692adeedb62653c0ace6d80b49686f61c585b60`. README rows 58 and 59
are both preserved. The three terminal production/test Lua files are unchanged
from the prior tested code; the merged Wallabag metadata fix is included, not an
unmerged dependency. Published merge/code `0e11080b513f0be0200b45f93bedc1be703bfedd`
has tree `f6302bba9c993fa6e5fd11d5a8c11175f333be23`, identical to local tested merge
`457093174c13d37af4d0805a6e1114eb673cb7a2`. This report-only successor changes no
executable code or tests.

Fresh results on that combination:

- **24/24** focused units; **280/280 across 18 selected suites**, adding the
  accepted Wallabag-null suite to the previous 17. No selected exclusion.
- **277/277** checks in eleven emulator scenarios, adding scenario 58 to the
  previous ten. Applicable budgets pass; scenario 59 repeats **3 × 57/57** in
  fresh profiles.
- Fresh changed-line unit coverage **6/6**; configuration-aware lint **0**;
  original size and whitespace checks pass.
- An initial combination command used two abbreviated suite filenames and stopped
  at the first missing file after four suites. That incomplete attempt is excluded;
  the corrected complete command produced the totals above.

The prior main-83 negative controls remain attributed to main-83; this merge
changes neither the baseline terminal source nor the candidate's terminal files.
The historical 267/249 totals are not added to or relabeled as the new 280/277
combination. Native-asset, physical-device, shell and coverage limitations above
remain unchanged. Exact-head CI and normal formal review are separate gates.


## First review: Japanese tap-cycle correction (historical)

This section records the first correction, later refined by the explicit-command
versus BS contract below. The formal review found a real gap in the initial class-call solution: Japanese
left/right wrappers also end the keitai multi-tap window. Bypassing that state
notification lets a subsequent tap replace an earlier displayed kana by sending
backspace plus a cycled character. This was not covered by the initial 24 cases.

The Japanese layout now registers an optional `onExternalCursorMove` notification
using the existing reversible method wrapper. Terminal left/right display-motion
methods invoke it on their `skip_callback` path, including no-op boundary moves,
matching the former Japanese navigation notification. It only clears the Japanese
tap timestamp, not other input-method state. Existing callbacks are preserved and
restored when the layout is unwrapped. Received text still bypasses input wrappers;
Chinese candidates, ordinary user navigation and intentional terminal replies are
unchanged. This does not add a general composition or ANSI rewrite.

Six additional units cover received BS, VT52 left/right, CSI left/right and callback
restoration. Scenario 59 adds real Japanese VirtualKeyboard taps before and after
a received left movement. It uses the valid ten-second keitai setting and asserts
that the second tap really falls inside that window; there is no mocked clock.
The received display remains unchanged and captured input has no stale backspace.

Latest code object `1d5b147affd021c51760fe7f8ab87e30de046bb9` has tree
`ff94889b6fcdc1408ff606fe6ee43f4fa7a4f542`, identical to local tested code
`1a9faf458340ca60b58d30a684692082d2922467`, on accepted main-84. The following
report-only successor changes no executable code or tests.

- **30/30** focused units; **286/286 across the same 18 selected suites**.
- **289/289** checks across the same eleven emulator scenarios; applicable
  budgets pass. Scenario 59 repeats **3 × 69/69** in fresh profiles.
- Fresh changed-line unit coverage **9/9** across both production files;
  configuration-aware lint **0**, original size and whitespace checks pass.
- Exact previously reviewed head `45aaa735`: **24 pass / 6 failures**, with all
  five stale-cycle cases sending the unwanted replacement; the real scenario
  receives three transmitted segments instead of two after the second tap.
  The candidate is restored and compared after these controls.
- An independent agent separately ran **30/30 units and 69/69 integration checks**
  in an isolated runtime pinned to these production hashes and found no actionable
  issue. It reused the native emulator assets, did not run a shell/PTY backend,
  and is not an independent full-CI or physical-device certification.

An initial new unit fixture incorrectly passed nonempty text to `initTextBox`
without populating `charlist`, causing identical geometry errors before and after
this correction. It was replaced by the real terminal display-add method; those
initial harness errors are excluded from all negative and positive evidence above.
The historical 24/267/249 and 24/280/277 results remain separately attributed, not
relabeled or combined into these final totals. Formal review and exact-head CI
remain necessary gates.

## First corrected main-87 combination (historical)

Accepted base is `edb652a5c5ffd023e1db85caffa1c5df34b538d3`. README rows 58/59/60
all remain. Published merge/code `f609346ca4cefd266b38b657e809d11f12aa1014` has tree
`828ad9a8a8826ce4a8301c2f9c9908733d61fd81`, equal to local tested merge
`6abdc1215c15d77136fa640ba11855329912f890`. The two production files and terminal
unit/scenario files are unchanged from the reviewed hook correction above.

Fresh results: **30/30 focused**, **300/300 in 19 selected unit suites** and
**344/344 in twelve emulator scenarios**, adding the accepted Japanese selection
suite and scenario 60 to the preceding combination. All applicable budgets pass;
scenario 59 repeats **3 × 69/69** in fresh profiles. Fresh changed-line unit coverage
is **9/9**, configuration-aware lint **0**, and original size/whitespace checks pass.
No selected unit exclusions. These counts supersede rather than add to 286/289.

The independent 30-unit/69-check rerun remains attributed to the hook snapshot
before this main-87 merge; the candidate files are identical, but no independent
full-combination rerun is claimed. The subsequent report-only commit changes no
production/tests. Earlier negative controls retain their original exact-head
attribution. Native-assets/device/shell limitations and normal CI/review gates
remain unchanged.


## Second review: composition state and deterministic tests

Korean and Vietnamese state also survived the initial navigation bypass. Exact
controls confirmed the same stale-anchor deletion for Chinese pinyin and stroke.
After explicit cursor movement, a subsequent key could send backspace and replace
text belonging to the old composition. The old Chinese test checked only that the
candidate changed, not that its anchor remained valid; it was insufficient.

Blindly clearing state on every received backspace is also wrong. With ordinary
per-key synthetic echo, the first correction turns Japanese `あ → あ → あ` into
`いあ` rather than `う`: its own replacement BS clears the tap window. Korean and
Vietnamese replacements need their BS echo to preserve composition too. Current
fork `Terminal:transmit` schedules refresh; it does **not** synchronously refresh.
An additional synchronous callback probe was a private reentrancy stress test,
not a claim about the real backend. Published units and integration use captured
bytes delivered after each key instead.

### Bounded final contract

- Only explicit received **VT52/CSI left/right commands** request the optional
  state notification, including no-op commands at a boundary. Received **BS** is
  treated as display editing/possible replacement echo and does not notify.
- Japanese clears its tap timestamp, Korean clears its FSM, and Vietnamese plus
  both Chinese layouts clear their composition stack. These notifications do not
  send deletion keys or invoke `separate`. Existing callbacks and nil/non-nil
  unwrapping are preserved. Ordinary keyboard/navigation wrappers remain active.
- Already displayed candidate hints are not retrospectively erased at a moved
  cursor. Tests with hints enabled check that notification itself emits nothing,
  leaves displayed bytes alone, and subsequent fresh input sends no stale delete.
- This is not recognition of every shell repaint origin. Applications may also
  use CSI commands to redraw; arbitrary repaint/fragmented ANSI streams and full
  terminal composition semantics remain outside this contract. There is no echo
  prediction queue, shell/PTY execution or physical-device certification.

The real Japanese UI test now checks that the first tap creates state and explicit
navigation immediately clears it, then verifies the next real tap sends a fresh
character. It has no wall-clock deadline assertion: the old timestamp does not
become nil merely because a slow runner waits. Unit-only multi-tap controls load a
private Japanese layout with a fixed clock; the shared `ui/time` and UIManager
clock are untouched, with global `now` identity checked during cleanup. This
supersedes the historical ten-second UI assertion.

### Final validation on accepted main-87

Code object `f0e10992b71ed1333690ee192aa2b5dd3dcc60bb` has tree
`19a05b7164cf7900e755d5b2fe3517b354a7cf22`, equal to local tested code
`250fcf88ce54ff7eb023649f8bf918d3cb391276`. The report-only successor contains no
further executable/test changes.

- **59/59** focused units; **329/329 in the same 19 selected suites**.
- **391/391** checks in the same twelve emulator scenarios; applicable budgets
  pass, with scenario 59 **3 × 116/116** in fresh profiles.
- Fresh changed-line unit coverage **18/18 across six production files**;
  configuration-aware lint **0**, original size and whitespace checks pass.
- Exact prior head `d9a715fd`: **36 pass / 23 failures**, covering stale state,
  hook installation and the over-broad Japanese BS reset, not 23 device bugs.
  The real UI control fails on Korean input after received navigation because it
  sends stale deletion. Candidate files are restored and compared afterward.
- Independent review separately passed **59/59 units and 116/116 UI checks** on
  the same production implementation. It is not a full-combination rerun or a
  native rebuild. The final IT local-variable rename is behavior-neutral; the
  author's final combined/repeated runs include it.

The earlier 30-unit/69-check and 300/344 evidence is historical, not relabeled as
this revision. Fixture refinements also corrected a right-motion setup to provide
an actual trailing destination and allowed Chinese candidate length to change;
the final controls check the real anchor and protected prefix rather than assume
all candidates have one character. All earlier device/native-assets/coverage
limitations and required normal CI/formal-review gates continue to apply.
