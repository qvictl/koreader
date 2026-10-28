# Contributing to the qvictl KOReader fork

本仓库是 KOReader 的独立维护分支。欢迎任何 PR——无论由人编写还是由 AI 编写。我们以**测试**而非作者身份把关。
This repository is an independently maintained fork of KOReader. Pull requests are welcome, whether written by people or by AI: we gate on **tests**, not on authorship.

## Branches

| Branch | What it is |
|---|---|
| `main` | The fork's line (default branch): upstream KOReader `master`, plus the fork's changes. All PRs target `main`. |
| `upstream` | A pure mirror of [koreader/koreader](https://github.com/koreader/koreader) `master`, fast-forwarded weekly by the *Upstream sync* workflow. Never commit to it. |
| `sync/upstream-<date>` | Automated weekly merge of `upstream` into `main` (a PR to `main`). Merge it with a **merge commit**. |
| `stable/<tag>` | The fork's changes backported onto an upstream stable release, used to build the Lua overlay for devices on that release when `main`'s changes don't apply to it automatically. |
| `master` | Legacy branch from when this was a plain GitHub fork. Not maintained. |

The `base` submodule points at [qvictl/koreader-base](https://github.com/qvictl/koreader-base) `main` (same model: `main` + `upstream`).

## What every PR needs

1. **Tests for any code change.** If your PR changes code (`frontend/`, `plugins/`, top-level `*.lua`), it must add or update tests in `spec/`:
   - unit tests in `spec/unit/` (busted, run with `make testfront`), and
   - for every **user-visible feature or fix**, at least one emulator integration scenario in `spec/integration/scenarios/` (see [spec/integration/README.md](spec/integration/README.md)), added or updated. Name it in the PR description.

   The required **Tests policy** check fails when code changes come without any `spec/` change. Only a maintainer can waive it, by applying the `no-tests-needed` label, and only for changes to documentation, comments or log message wording.
2. **Coverage gates** (required **Coverage** check; policy in [`.ci/coverage_config.lua`](.ci/coverage_config.lua), tool in [`.ci/fork/coverage.lua`](.ci/fork/coverage.lua)). Line coverage is measured with luacov on the unit tests and on the emulator integration tests (including their subprocesses), on every PR:

   | Gate | Requirement (blocking) |
   |---|---|
   | Diff coverage, **unit tests** only | ≥ **80%** of the changed executable Lua lines |
   | Diff coverage, **unit + integration** | ≥ **90%** of the changed executable Lua lines |
   | **Overall** coverage (`frontend/` + `plugins/`) | must not drop below `main`'s (ratchet, ± 0.1 pp noise allowance) |
   | **Fork-owned modules** ([`.ci/owned-modules.txt`](.ci/owned-modules.txt)) | each ≥ **80%** from 2026-10-27, **85%** from 2026-11-24, **90%** from 2026-12-22 |
   | **Overall unit-test coverage** (`frontend/` + `plugins/`, unit tests only) | ≥ **36.47%** from 2026-11-24, ≥ **41.47%** from 2026-12-22 (day-one 31.47%; not enforced before those dates) |

   - *Fork-owned modules* are the modules the fork added or changed: for an upstream file the fork changed, its scope is the fork's own lines (`fork`) or the fork's functions (`func:`); modules added by the fork count as a whole (`file`), and are included automatically even before being listed. Add new fork modules to the list. The dated targets tighten by themselves.
   - The overall coverage of `frontend/` + `plugins/` had a day-one baseline (2026-10-27, see `.ci/coverage_config.lua`); targets: baseline **+5 pp** by 2026-11-24 and **+10 pp** by 2026-12-22 (tracked and reported, not blocking — the ratchet is what blocks).
   - The unit-test-only coverage of `frontend/` + `plugins/` has its own dated targets (`overall.unit` in `.ci/coverage_config.lua`), blocking from their date; the plan to get there (per-file priorities, batches) is [doc/coverage-plan.md](doc/coverage-plan.md).
   - Upstream sync PRs (`sync/upstream-<date>`) only enforce the owned-modules gate (upstream's own changes are not ours to cover); the diff and ratchet values are reported.
   - The `main` baseline, the history and the badges live on the [`coverage`](../../tree/coverage) branch ([`HISTORY.md`](../../blob/coverage/HISTORY.md)), updated by CI on every push to `main`.
   - Every PR gets a coverage comment and job summary: the 5 gates, the owned modules table, and the changed lines no test runs.
3. **All CI checks green** (required by the branch protection of `main`):
   - **Lint**: upstream's lint (`.ci/check.sh`: luacheck, shellcheck/shfmt, unscaled sizes, gettext…);
   - **Build and unit tests**: emulator build, base & front unit tests, Kindle HF / PW2 builds;
   - **Integration tests**: the emulator integration scenarios, including their memory and latency budgets;
   - **Coverage** and **Tests policy** (see above).
4. **Test evidence in the description**: what you tested and how, and which integration scenario covers the change (see the PR template). For performance or memory changes, give before/after numbers (the integration scenarios' metrics are in the job summary and the `integration-results` artifact).

## Review and merge

Every PR to `main` is reviewed by AI reviewers (CodeRabbit, Gemini Code Assist) and evaluated by the *Review gate*
workflow, which keeps a checklist comment on the PR. The gate approves and enables auto-merge only when all required
checks pass, an AI reviewer reviewed the head commit without requesting changes, every review thread is resolved, the
change is small (≤ 500 non-test / non-doc lines) and touches no sensitive path (CI, policy, release / OTA tooling, build
scripts); otherwise a maintainer decides (`human-approved` label). AI comments flagged as potential issues / bugs must be
fixed or answered with a justification before resolving them. Full rules, override and activation steps:
[REVIEW_POLICY.md](REVIEW_POLICY.md).

所有合入 `main` 的 PR 由 AI 审查（CodeRabbit、Gemini Code Assist）并经 *Review gate* 评估；只有全部条件满足时才自动批准和合并，
否则由维护者决定。AI 标出的潜在问题 / bug 必须修复或回复理由后才能解决对话。详见 [REVIEW_POLICY.md](REVIEW_POLICY.md)。

## Running the tests locally

```sh
./kodev build                                     # build the emulator (or: make)
make testfront                                    # unit tests (front)
./tools/run_integration_tests.sh                  # integration scenarios (headless, SDL dummy driver)
./tools/run_integration_tests.sh dictionary       # only the scenarios whose name contains "dictionary"
./tools/run_integration_tests.sh --coverage       # with luacov (stats in integration-results/)
make coverage-run                                 # unit tests with luacov
```

## Upstream

Changes made here are **not** submitted upstream. Upstream is merged weekly into `main` through a PR (`sync/upstream-<date>`); if a merge conflicts, an "Upstream sync conflict" issue is opened listing the conflicting files, to be resolved by hand. If upstream can no longer be merged cleanly, the fork continues independently.

## Releases

- Push a tag `vYYYY.MM.qN` (e.g. `v2026.10.q1`; no `-`: `tools/describe.sh` and the version parsing expect `vYYYY.MM[.P]` before any `-`) on a commit of `main`: the *Fork release* workflow builds the Kindle packages (kindlehf, kindlepw2), the x86_64 emulator and the Lua overlays for upstream stable releases, runs the integration tests, and publishes a GitHub release.
- The rolling `nightly` prerelease is rebuilt from `main` daily when it changed (or manually: run *Fork release* on `main`). Its assets have stable names, e.g. `koreader-emulator-x86_64-latest.tar.xz`.
