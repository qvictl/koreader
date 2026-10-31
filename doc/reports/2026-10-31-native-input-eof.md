# Native input EOF: Linux emulator regression (2026-10-31)

Companion base fix: [qvictl/koreader-base#36](https://github.com/qvictl/koreader-base/pull/36).
The upstream [Kindle Scribe report #2504](https://github.com/koreader/koreader-base/issues/2504)
was closed as `not_planned`; current fork main still reproduced its repeated-EOF
polling behavior. The base patch retires the closed producer and preserves final
input events. It does not restart `lipc-wait-event` or establish why it was killed.

`35_native_input_eof` opens a real EPUB ReaderUI and a separate native input
instance backed only by owned Linux pipes. An empty producer closes first; the
next producer has a final page-forward press/release and then EOF. The scenario
checks the one-shot `InputError`, actual fd closure, preservation of both key
events, frontend `onKeyPress` translation and no recurring warning. The returned
key is sent through UIManager and must turn the real reader to page two. A normal
SDL tap then turns to page three, showing the emulator input was not replaced.

The scenario uses the Linux-emulator `libkoreader-input-test.so` fixture added by
the base PR. It compiles actual production input C with only hardware fake-event
production unavailable. Device builds do not contain that fixture. There is no
simulated `select`, `read`, EOF or Lua event-handler result.

## Evidence and limits

- Exact base candidate `b640fd21cf43aaa5ad86ad75a93f1a9e5a8f599f`: host native fixture
  compiled with `-O2 -fvisibility=hidden -Wall -Wextra -Werror`; six unit tests pass.
  Old main `cc2be6a` compiled into the same fixture fails all six assertions.
- The real UI scenario with the old module fails at the fd-closure assertion;
  the fixed module passes all eight assertions plus the two page-turn waits
  in three consecutive isolated runs (1.2 s, 1.3 s and 2.7 s). All 592 overlaid
  core/base runtime Lua files match the tested source byte-for-byte.
- Linux native fixture + normal emulator build, FFI declaration checks, binary
  checks and **38/38 complete base unit suites** pass in
  [CI 41160236077](https://github.com/qvictl/koreader-base/actions/runs/41160236077).
  Required lint, tests policy and coverage checks are green at that exact head.
  Lua-only diff coverage is not a measurement of changed C lines.
- Local UI validation reuses the fork's `v2026.10.q1_emulator` native runtime with
  current core/base Lua overlays and a locally rebuilt input shared library.
  SDL3 3.4.18 was locally source-built for headless execution. This is not a full
  native emulator rebuild, Kindle cross-build, hardware suspend/resume result,
  nor proof that losing the power-event listener is harmless.

This branch must pin the actual base main merge commit before leaving draft;
it must not move the gitlink to an unmerged candidate. No release/version change
or device installation is part of this regression work.
