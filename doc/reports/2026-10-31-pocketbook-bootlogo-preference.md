# PocketBook: preserve the firmware boot-logo selection

## Evidence and bounded scope

Upstream [issue 15178](https://github.com/koreader/koreader/issues/15178) reports that exporting a cover replaces the PocketBook boot logo even when the user chose the default, current page, random, or another image. The current fork's `CoverImage:updatePocketBookBootLogo()` unconditionally runs `sync` and `iv2sh WriteStartupLogo` on PocketBook.

The upstream discussion provides a configuration guard using `bootlogo == "@cover_logo"`. Later comments confirm it on [InkPad Color 3 and Verse Color Pro](https://github.com/koreader/koreader/issues/15178#issuecomment-6434810469), with [clarification that the reported patch works without sync](https://github.com/koreader/koreader/issues/15178#issuecomment-6452820232). These are upstream user observations, not hardware validation performed here.

This patch adopts only the preference guard. It does **not** add power-off logo handling, symlink/copy fallbacks, device-path cleanup, or a different command/background/sync policy. The existing `sync` remains for an explicitly selected cover logo; removing it would be a separate compatibility/performance decision.

## Implementation contract

- Query the already-used `ffi/inkview` binding only on PocketBook. The pinned base `d1b27196eac53e8c810c63762ed6bfb40f226382` declares `GetGlobalConfig()` returning `iconfig *` and `ReadString(config, key, default)` returning `const char *`.
- Read `bootlogo` with the default `@default_boot_logo`; only an exact `@cover_logo` value authorizes the existing boot-logo command. Query on each update rather than caching the selection.
- Check NULL configuration/string pointers before conversion. Missing SDK symbols, load failures or Lua errors are contained and logged. If the preference cannot be read, leave the current boot logo untouched rather than guessing the user's choice or crashing the reader.
- The configuration and returned string are borrowed SDK values; this does not acquire a new configuration object or add a release obligation.
- Normal cover image export, cache updates and non-PocketBook behavior remain unchanged. Failing to read this optional preference may prevent the boot-logo update, but does not discard the exported cover file.

## Exact validation snapshot

All local results below apply to code/test commit `5efa68bcbb63f7ea7b93ce54a2c68ecc14e0a9e5` (tree `2f583a9350f015b3922d68d48d6eb46ec46b61d4`) over accepted main `8e5dac18f9b2eea48a97c8ae5aa0f71b217e7984`. The production plugin blob is `bf4b1d8dab9df061884ccf08993ad4c947f4c3fd`. The published code/test tree was verified byte-for-byte against the locally tested tree. This report is a subsequent documentation-only addition. Any later main integration needs separately attributed results rather than relabeling these measurements.

| Check | Result on the snapshot above |
| --- | --- |
| New boot-logo unit tests | 15/15: non-cover values, exact cover value, changing preference, non-PocketBook, NULL config/string, throwing config/read and missing binding |
| Related unit tests | 94/94 across eight separate native processes: new suite (15), document registry (6), document settings (11), settings locations (25), UIManager (20), plugin loader (6), image widget (1), document (10) |
| Changed-line unit coverage | 10/10 executable lines (100%) with the fork coverage tool; partial changed-line measurement, not a whole-repository coverage claim |
| New emulator scenario 48 | Three fresh profiles, 17/17 checks each (51/51 total) |
| Related emulator scenarios | 01/09/19/48: 37/37 checks and applicable existing startup/suspend budgets pass |
| Independent review | Static code and evidence-log review found no remaining blocker; no independent native rerun |
| Lint / whitespace | Luacheck API with repository options: zero warnings/errors; `git diff --check` passes |

Scenario 48 opens a private synthetic EPUB in real ReaderUI with a real custom PNG cover. The production cover plugin decodes and writes actual BMP bytes, including its cached rotation path. It verifies that non-cover choices produce no boot-logo commands, an explicit cover choice retains the original escaped command, later setting changes take effect, an SDK error neither overwrites the logo nor blocks actual page turns, retry works, and close/reopen preserves the reading position. Only the PocketBook capability during the synchronous plugin hook, InkView configuration and command execution are synthetic. No captured shell command is executed; no physical device logo or settings are accessed. Cleanup restores all modified boundaries/settings before protected reader close and retains private inputs inside isolated KO_HOME for any normal worker/process teardown.

Negative controls use unchanged production code from main `8e5dac18`: the new unit suite has 1 pass and 14 assertion failures; the real scenario exports a valid BMP but still records two device commands for the default firmware logo (expected zero). Restoring the candidate makes the same path pass. Earlier test-harness failures from recursive widget equality and an incorrect assumption that the FileManager instance survives book reopen are excluded from the passing evidence; they required no production-code change.

Native libraries come from the owner-authorized fork Linux emulator, with matching Lua source and pinned base helper. There is no physical PocketBook/ARM execution or measured flash-write/battery claim. Exact published tree verification, required CI and normal CodeRabbit/merge gates remain separate requirements.
