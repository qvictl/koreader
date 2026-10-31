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

User keyboard methods are still wrapped. No keyboard implementation, shared
method-wrapper helper or IME state machine is changed, and no temporary global
callback suppression is used. The intentional VT52 identification reply remains
an outgoing response. Other parser operations have no overlap with the inspected
keyboard wrappers and are unchanged.

This is **not** a general terminal/IME composition rewrite or an ANSI/UTF-8 stream
parser certification. Existing control-C callback handling outside the receive
parser, arbitrary partial escape/UTF-8 sequences, complete interactive editing,
shell supervision and hardware behavior are not covered or claimed fixed.

## Tests

`terminal_ime_output_spec.lua` has 24 cases covering literal UTF-8 output for six
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
source/log inspection rather than an independent runtime run. Exact-head CI and
formal review remain required before any merge.
