# Preserve sidecar sources when migration fails

## Discovery and scope

Inspection following the 2026-10-30 upstream triage found unchecked migration
failures in `DocSettings:flush` and `DocSettings.updateLocation`. The same paths
remain in the [current upstream source](https://github.com/koreader/koreader/blob/master/frontend/docsettings.lua)
retrieved on 2026-10-31 (file blob `202b392fc9c14159cbad34847f0aeca5e78846e0`),
and fork main `3933787fb891befec8b6e2088f9b67db8da5595c`.

This is an independently reproduced defect, not a claimed resolution of a
particular existing issue. Searches of upstream/fork sidecar, metadata-copy and
rename reports found no exact duplicate fix. Related upstream
[PR 11878](https://github.com/koreader/koreader/pull/11878) prevents FileManager
pasting a book onto itself; it does not prevent distinct extension-only book
names from sharing a sidecar directory. Existing fork location cleanup and
FileManager command-failure fixes are preserved.

Actual filesystem tests, without mocked copy/write results, demonstrate:

1. Changing metadata storage successfully writes the main settings, but a
   permission-denied or directory-collision custom-file copy still deletes the
   source cover/custom metadata.
2. Renaming a book and failing to save its destination settings still purges
   its original sidecar, including the only saved annotations.
3. A reported custom-file copy failure during rename also purges all original
   sidecar files, including successful source files and annotations.
4. Extension-only renames/copies share a `.sdr` directory. Copying custom files
   onto themselves truncates them; the subsequent old-sidecar purge can also
   delete the shared files. Updating the same document path has the same risk.

Ten new regression cases fail against original production; a positive ordinary
copy control passes. A real emulator FileManager rename reproduces deletion of
the saved ReaderUI bookmark sidecar when its destination cannot be opened.

## Fix

- During flush, remove each custom source and clear its cached path only after
  `copyFile` reports success. Failed sources remain available for later retry.
- During updateLocation, stop if required destination settings cannot be saved;
  fallback directory creation is only for custom-only sidecars.
- Do not purge source metadata unless all required custom copies report success.
- Skip identical source/target custom paths. On successful migration, explicitly
  retain the destination main sidecar and purge only non-shared custom sources.
- Preserve existing copy, hash-location, deletion and archive behavior.

This is **source-retention protection for detected failures**, not an atomic
multi-file transaction. The book rename may already have succeeded; retained
old metadata can require explicit retry or manual recovery. The test removes
its synthetic obstruction and explicitly retries `updateLocation`. There is no
new automatic retry or user-facing migration-status notification.

The pinned lower-level copy helper now propagates read/write/close errors, and
current main's write helper checks write/flush/close results. This is still not
atomic replacement: an existing destination can already have been overwritten
in place, and partial migration may leave destination files alongside preserved
sources. No power-loss, fsync-durability, same-inode-alias, or general transaction
guarantee is claimed.

## Validation

- **175/175 native tests:** eleven new migration cases, the existing DocSettings
  suites, FileManager operations and ReaderBookmark tests, plus LuaSettings,
  settings-write-failure and collection-flush compatibility suites. Cases include actual
  destination-directory collisions, enforced read-only directory permissions,
  retry after removing obstructions, custom-only sidecars, shared paths,
  rename/copy, ordinary deletion and archival. The permission case is skipped
  on hosts that do not enforce permissions; collision cases remain portable.
- **30/30 changed executable production lines covered (100%)** with the existing
  diff-coverage gate; whole-repository coverage is not measured.
- **Four independently authored reproduction tests** fail on old production and
  pass on the candidate. An independent agent reviewed the failure mechanism;
  this is not a claim of completed formal CodeRabbit approval.
- `42_sidecar_migration_failure`: **32/32**, three fresh repeated emulator runs,
  plus the initial successful run. Real painted rename dialogs, real file moves,
  native EPUB reading, bookmarks, custom metadata, source-byte retention,
  explicit retries and shared-sidecar renames are exercised. Reopening restores
  the saved page and bookmark note, and page turning still works.
- Related scenarios `16_filemanager_input_lifecycle` and
  `18_shortcut_folder_rename` pass **13/13** and **5/5**, respectively, in each of
  three fresh runs. Old production fails scenario 42's annotation-retention
  assertion; the integration harness records the failure.
- Merged current fork main `b26341d`, including PR 66's write-error propagation,
  without production conflicts. All 175 related tests and scenarios 16/18/42/43/44
  pass on the combined tree; each scenario passed three fresh runs, **246/246
  checks** in total.
- Lua lint and `git diff --check` pass.

All **157 front suites** were attempted in isolated Busted processes: **154
suites pass, with 2,201 successful cases**. Three unchanged environment blockers
remain: unavailable `msgfmt`, prohibited `getifaddrs`, and four live translator
DNS failures. No restriction was bypassed; this is not a clean full-suite pass.
Required remote CI/build/review gates still apply and are not weakened.

## Lower-level copy follow-on and actual base pin

CodeRabbit correctly identified that the original `ffi.util.copyFile` ignored
failed reads, writes and closes. Checking its return value alone could not retain
a source when the helper falsely reported success. [Base PR 37](https://github.com/qvictl/koreader-base/pull/37)
now propagates those errors and attempts to remove partial regular destinations
while retaining the nil-success/error-string API. It was accepted through the
normal review gate and merged as **`d1b27196eac53e8c810c63762ed6bfb40f226382`**;
this PR pins that actual merged commit. The merged tree was verified byte-equal
to reviewed head `507bef36`; its only production change from prior base `cc2be6a`
is `ffi/util.lua`. Base PR 36's separate input work is not included, and its
explicit user-confirmation hold remains untouched.

`44_sidecar_copy_io_failure` uses an actual child process that first saves main
ReaderUI settings, then lowers only its own Linux `RLIMIT_FSIZE`. A large custom
cover fails during write, while small custom metadata fails at buffered close.
Source bytes and annotations survive, partial destinations disappear, and an
unrestricted retry restores the custom title, bookmark and reading page. Old
helper production fails source cover retention. No copy result is fabricated.
It passes **13/13** checks, including three final repeated runs alongside the
other combined scenarios above.

The helper independently passes **90/90** related native tests, all 11 generated
POSIX declaration variants, and its unchanged diff80 gate (**16/17, 94.1%**).
Formal review also tightened cleanup boundaries: source-close-only errors retain
completed targets, and cleanup preserves destination symlinks without restoring
their overwritten referents. Both regressions fail the prior helper candidate;
independent review reruns **12/12** successfully. Test teardown explicitly unlinks
the owned link before recursive cleanup, even after removing its referent;
**10×12/12** repeated tests pass. All three formal findings were accepted and
resolved by CodeRabbit; final Linux CI, macOS architectures and Tests policy pass.
The macOS x86 transient DNS download failure passed on targeted retry.

This strengthens detected-copy-failure handling only. It remains non-atomic,
without fsync or power-loss guarantees; same-inode aliases and best-effort cleanup
races are not solved. PR 65's original finding remains for the reviewer to verify
against this final pin and scenario update; approval is not presumed.

## Runtime and delivery boundary

All 500 production Lua files are overlaid from the candidate and compared against
the checkout. The native emulator is reused from the existing verified fork
artifact with the actual merged base's Lua files overlaid/verified and an isolated
SDL3 library. Native code is unchanged by the base pin. This is not a fresh native build or Kindle hardware validation.
Only owned synthetic files and isolated profiles were used. No upstream
submission, release or device installation is part of this change. Publication
and included public-fork review may proceed through the existing gate; no paid
add-on activation is authorized.
