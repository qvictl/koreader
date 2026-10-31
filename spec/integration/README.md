# Emulator integration tests

These tests run the **real KOReader emulator** (the x86_64 build, `koreader-emulator-x86_64-linux-gnu/koreader`),
headless, and drive it through scripted scenarios: opening books, turning pages with tap and swipe gestures, using
the TOC, looking up words in dictionaries, suspending… They check the results, and **budgets** (time, memory).

```sh
./tools/run_integration_tests.sh                       # all scenarios, on the emulator built in this tree
./tools/run_integration_tests.sh dictionary sdcv       # scenarios whose file name contains "dictionary" or "sdcv"
./tools/run_integration_tests.sh --kodir DIR           # another KOReader install directory (e.g. a release tarball)
./tools/run_integration_tests.sh --coverage            # with luacov (budgets only reported)
./tools/run_integration_tests.sh --repeat 5 memory     # flakiness check
./tools/run_integration_tests.sh --help
```

Results go to `integration-results/`: `summary.md` (also shown in the CI job summary), `junit.xml`, `timings.json`
(every metric and budget), per-scenario `results/*.json` and KOReader logs in `logs/`.

## How it works

- `tools/run_integration_tests.sh` generates the fixtures (`fixtures/make_fixtures.py`: small synthetic or public
  domain EPUBs in English, Chinese and Japanese, and StarDict dictionaries, one of them HTML with a big `res/`
  directory), then, for each scenario, starts KOReader with a fresh `KO_HOME` (settings, caches, history), the SDL
  `dummy` video driver (no X server needed; set `SDL_VIDEODRIVER` to override), a 1072x1448 screen at 300 dpi, and
  `driver.lua` loaded as a user patch.
- `driver.lua` runs the scenario in a coroutine, resumed from UIManager tasks, so the real event loop keeps running
  (painting, scheduled tasks, subprocess polling) while the scenario waits. User actions go through `T:run()`, from
  the main context, like real input events. When the scenario ends (or fails, or times out), it writes the result and
  quits KOReader. A Lua error in the UI loop kills the process: the runner reports it as a crash, with the log.
- The runner exits with a non-zero code if any scenario failed.

## Writing a scenario

A scenario is a file in `scenarios/` returning a table:

```lua
return {
    name = "What it tests",
    timeout = 120,                -- seconds (also used by the runner's watchdog)
    settings = { ... },           -- merged into settings.reader.lua before KOReader starts
    setup = function(T) end,      -- optional, run synchronously during startup (e.g. to install spies)
    run = function(T)
        local ui, open_ms = T:openBook(T:fixture("books/en.epub"))
        T:budget("open_ms", open_ms, 15000, "ms")
        T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h / 2))   -- next page
        T:waitUntil(function() return ui:getCurrentPage() == 2 end, 5, "page 2")
        T:closeBook()
    end,
}
```

The `T` API (see `driver.lua`): `T:run(fn)` (UI action, main context), `T:wait(s)`, `T:waitUntil(pred, timeout, what)`,
`T:check(cond, msg)` (aborts on failure), `T:expect(cond, msg)` (goes on), `T:eq(a, b, msg)`, `T:metric(name, v, unit)`,
`T:budget(name, v, max, unit)`, `T:tap(x, y)`, `T:tapWidget(w)`, `T:tapEvent(x, y)`, `T:swipe(x, y, dir)`,
`T:repaint()`, `T:openBook(path)`, `T:closeBook()`, `T:fileManager()`, `T:reader()`, `T:topWidget()`,
`T:findWidget(root, pred)`, `T:rssKb()`, `T:luaKb()`, `T:fdCount()`, `T:fdList()`, `T:children()`, `T:spy(obj, method)`,
`T:fixture(path)`, `T.startup_ms`, `T.screen_w`, `T.screen_h`. `dicthelper.lua` has helpers for dictionary lookups.

With `--coverage`, subprocesses started with `util.runInSubProcess` save their own luacov stats too
(`driver.lua`), so the code that only runs in children is measured. The release candidate workflow merges the unit and integration
stats for the coverage gates (see CONTRIBUTING.md).

Budgets are deliberately generous (CI runners are slow and noisy): they catch regressions by an order of magnitude,
not by a few percent. `IT_BUDGET_SCALE=2` doubles them all.

## Scenarios

| Scenario | Covers |
|---|---|
| `01_startup_filemanager` | startup to the file manager, books listed, tap on a book opens it; startup budget |
| `02_english_epub` | EPUB: page turns (tap, swipe), TOC (tap on an entry), go to page; open/turn/close budgets |
| `03_cjk_epub` | CJK EPUB with the bundled Noto Sans CJK SC: text extraction, word selection, page turns, CJK TOC, re-rendering |
| `04_dictionary` | classic lookups: several dictionaries in order, HTML dictionary, CJK word, no result (fuzzy / non-fuzzy dialog), `res/` skipped by the .ifo scan, no sdcv left behind |
| `05_dictionary_progressive` | progressive lookup: first dictionary shown alone before the others finish, final list equals the classic one, early close kills the background lookup; latency budgets |
| `06_sdcv_res_dirs` | sdcv (base's `skip_res_dirs.patch`) does not walk into `res/`; per-lookup budget |
| `07_unpainted_tap` | taps on never painted Button/IconButton in the same UI tick (#16288): no crash, ignored; work once painted; `widgetInvert` inside a scrolling dialog's cropped area |
| `08_subprocess` | `runInSubProcess`: exit status, erroring and yielding tasks contained (no escaped child), bidirectional pipes, double fork, pipe creation failures (fd limit) without leaks; Trapper restores the caller's `dismiss_callback` |
| `09_suspend_resume` | power button (emulator screensaver), Suspend/Resume events, input inhibition, memory release on suspend |
| `10_low_memory_profile` | low memory profile: crengine storage factor 4, DocCache ≤ 32 MiB, memory released after open & close, open/close cycles |
| `11_memory_budget` | 10 open/turn/TOC/end of book/close cycles of 2 books: books reopen at their last page, each book is closed with its end of book dialog shown, which must go away with it; the RSS & Lua heap floors must not rise after warm-up (leak check) |
| `12_japanese_kana_guard` | Japanese plugin leaves kana-less text alone in non-Japanese books (no lookups), still handles kana / Japanese books; its menu option |
| `13_font_menu_faces` | font menu previews (incl. font-family sub-menus) don't keep their faces cached |
| `14_base_archive_serialization` | archive error recovery and packaging/reloading radix-safe serializer output, including infinities and NaN |
| `15_network_info` | native interface discovery, the network information event/dialog, displayed interface names and MAC addresses, and dismissal without external network requests |
| `21_font_lifecycle` | native collection preserves page counts and pixels over three real ReaderUI open/turn/close/reopen cycles; optional Linux RSS/PSS and FreeType-finalizer benchmark |
| `25_async_command_output` | multi-megabyte streaming command output, stdout EOF before shell exit, late descendant writers, cancellation after a prefix without killing the command, bounded background collection, UI heartbeats and pipe/pid cleanup |
| `27_kosync_default_http` | real localhost Spore HTTP: UI responsiveness, parent authentication, bounded workers, cancellation, failed fork and late progress responses across lifecycle changes |
| `28_cache_pressure` | byte-based PDF cache pressure eviction, original budget preservation, and real background reflow context cleanup before and after reader closure |
| `32_news_download_folder_safety` | real folder-selection and deletion confirmations: cancel preserves inert fixtures/settings, accept retains feed configuration, unrelated files/subfolders are deleted only after explicit consent, unreadable selection fails closed |
| `33_kosync_hostname_identity` | real localhost KOSync push, continued reading and manual pull: custom/default names and default-to-custom renaming do not rewind the same device; a different device ID still syncs |
| `34_footer_delayed_refresh` | real reading-order events followed by immediate document close; old footer tasks canceled, new reader feedback and page turns retained across repeated reopen cycles |
| `38_dictionary_sparse_history` | missing leading/interior lookup-history records: complete reverse-index display, repeated open/close in the file manager and reader, byte-preserving viewing, and tapping a surviving word for a real dictionary lookup |
| `39_kosync_invalid_url` | persisted malformed sync URL across book opens, failed pull/push/auth and queue preservation, blank-address UI recovery and valid localhost retry |
| `40_gesture_missing_coordinates` | real protocol-B frames with partial buddy slots, gesture/timer cleanup, ReaderUI page turns and reopen |
| `41_calibre_metadata_isolation` | painted Calibre search during synthetic wireless session, received book and metadata persistence, limited deletion, reconnect and EPUB reading |
| `42_sidecar_migration_failure` | real FileManager renames with blocked main/custom destinations retain source annotations and custom files; explicit retry, shared-sidecar extension rename, and ReaderUI reopen/page turns |
| `44_sidecar_copy_io_failure` | Linux child-only file-size limits cause real custom-cover write and buffered custom-metadata close failures; source bytes survive, partial files are removed, unrestricted retry succeeds, and ReaderUI restores the note/title/page |
| `47_kindle_wifi_failure` | real Wi-Fi TouchMenu, error dismissal, failed/successful retry, delayed disconnect, failed enable cleanup and resume recovery; only Kindle LIPC/hardware boundaries are synthetic and host shell commands are forbidden |
| `48_pocketbook_bootlogo_preference` | real ReaderUI and native cover export across reader-ready/rotation hooks; synthetic PocketBook settings permit boot-logo commands only for the explicit cover choice, fail safely, recover, and preserve reading after close/reopen |
| `49_http_proxy_credentials` | real loopback HTTP proxy and OPDS HEAD/GET catalog parsing with reserved Basic credentials; credential-free absolute targets, origin/explicit/global proxy forms, separate proxy authentication, URL credentials, and reading afterward |
| `50_readerstatus_stale_navigation` | real native PDF next/previous navigation, repeated queued requests, Home and replacement interruptions, duplicate confirmations, Cancel and FileManager confirmation compatibility |
| `51_coverlist_narrow_window` | real SDL window resize, native EPUB/custom-PNG cover extraction and cached collection/History rows; narrow fallback, wide restoration, repeated resize, page turns and reopening without changing cover preferences |
| `53_coverimage_format_persistence` | real format-menu checkmarks, saved settings and reader reopening; native RGB PNG cover exports remain color/grayscale BMPs, with mutually exclusive selections and reading progress preserved |
| `54_autowarmth_native_steps` | real activation menu, UIManager queued callbacks and Generic power conversion with synthetic solar time/light hardware; all 24 native warmth steps, preserved night-flag policy, schedule cancellation and native EPUB reading afterward |
| `55_readtimer_elapsed_time` | real timer menu/picker, input hooks and UI task queue with a synthetic timer-only elapsed clock; overdue expiry, snooze/repeat, auto-repeat on resume, timer transfer through FileManager/ReaderUI and native EPUB progress; a same-batch tap reaches the reader before the deferred expiry popup |
| `56_vocabulary_context_provenance` | native EPUB selected-word context, real sdcv and rendered-definition long-press, manual/automatic SQLite vocabulary capture, root versus nested edits, popup closure and reader reopen; no network |
| `57_keyboard_pdf_zoom` | native synthetic PDF, real keyboard dispatch, paging/panning, manual scale, bottom menu, flipping and close/reopen; skim modal uses explicit ReaderUI key dispatch (not physical modal routing); continuous/reflow and regional-free unit controls |
| `58_wallabag_null_metadata` | real Wallabag menu, JSON-null title/URL, EPUB export sinks, partial-failure retry and existing annotation retention, native EPUB opening/reopen; synthetic HTTP and file I/O failures only |
| `59_terminal_ime_output` | real InputDialog, VirtualKeyboard taps/layout replacement and terminal ANSI parser with synthetic received bytes and captured transmit; six layouts, UTF-8 output, cursor controls, explicit-navigation IME state reset, BS composition echo and repeated close/reopen; no shell, PTY or commands |
| `60_japanese_enabled_selection` | native Japanese EPUB hold gestures and sdcv with owned dictionaries; global enable/disable, Cancel/Save, preferred and book-disabled dictionaries, close/reopen, all-disabled selection and recovery |
| `62_pdf_current_zoom_factor` | real PDF zoom picker arrows, default confirmation Cancel/Save, Apply and unapplied Close, native tap page turns, overlap-only updates and repeated reopen; current book scale stays separate from the global default |
| `63_wikipedia_metadata_language` | native EPUB ISO metadata, actual Wikipedia result and language settings dialogs, Cancel/Save and remembered explicit editions; automatic normalization/deduplication preserves manual domains; synthetic API only |
| `64_style_tweak_notifications` | real profile Execute/notification menus, all three style-tweak actions, masked and painted feedback, batched profile execution message, ReaderReady auto-execution across reopen and native page turn |
| `65_calibre_inbox_initialization` | real Calibre menu and local metadata failure notice, queue/standby cleanup, repeated failed attempts, repaired-inbox handshake/enumeration, disconnect/reconnect and native EPUB reading |

The Linux-only `tools/benchmark_font_memory.sh` runs scenario 21 with RSS/PSS,
process peak RSS, timings and a test-only FreeType face-finalizer observer:

```sh
tools/benchmark_font_memory.sh --kodir /path/to/native/runtime \
  --output /path/to/results --book /path/to/book.epub --font 'Noto Sans CJK SC'
```

Run the baseline and candidate in separate processes with the same frontend,
book, fonts, screen settings and native dependency builds. Each run performs
three open/turn/close cycles on an isolated book copy and writes `memory.jsonl`, `faces.tsv`, screenshots
and the integration report. `faces_explicit` counts actual finalizations outside
library teardown; `faces_library_cleanup` identifies releases during
`FT_Done_FreeType`. Set `FONT_BENCH_EXPECT_ZERO=1` for the fixed runtime to also
assert that closed books retain zero native faces. The observer is never loaded
in normal CI or product runs. The script compares FreeType library paths with
and without the observer and verifies each intercepted symbol is bound to that
runtime library. Immediate `closed_` and 0.5-second `settled_` samples are separate;
normal integration tests add no fixed wait after closing. Output paths cannot
contain whitespace or colons because of LD_PRELOAD parsing. These are host measurements; device savings must
be measured separately. Use a fresh output directory for each run.

The benchmark samples `/proc/self` synchronously at each measurement boundary;
forking a sampler would alter the target process PSS. JSON and face traces are
kept in memory and exported together after the final sample. Reusing an output
directory clears both files before starting the observer.
