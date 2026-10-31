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

The lower-level copy and main-write helpers do not propagate every read/write/
close error. This patch therefore does **not** claim disk-full, short-write,
power-loss, symlink-alias, or general durable-write protection. Successful
partial migration may leave destination files alongside preserved source files.

## Validation

- **153/153 native tests:** eleven new migration cases, the existing DocSettings
  suites, FileManager operations and ReaderBookmark tests. Cases include actual
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
- Rebased onto current fork main `68a6b62` without production conflicts; all
  153 related tests and scenarios 16/18/42 pass again on that combined tree.
- Lua lint and `git diff --check` pass.

All 152 front suites were attempted in isolated Busted processes: 149 suites
pass, with 2,136 successful cases. This broader run preceded two additional
portable collision cases, both included in the final 153-test pass. Three
unchanged environment blockers remain: unavailable `msgfmt`, prohibited
`getifaddrs`, and four live translator DNS failures. No restriction was bypassed;
this is not a clean full-suite pass. Required remote CI/build/review gates still
apply and are not weakened.

## Runtime and delivery boundary

All 500 production Lua files are overlaid from the candidate and compared against
the checkout. The native emulator is reused from the existing verified fork
artifact with unchanged base `cc2be6a552998ca3ee379c1eec56db29df53beb9` and isolated
SDL3 library. This is not a fresh native build or Kindle hardware validation.
Only owned synthetic files and isolated profiles were used. No upstream
submission, release or device installation is part of this change. Publication
and included public-fork review may proceed through the existing gate; no paid
add-on activation is authorized.
