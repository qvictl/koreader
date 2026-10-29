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
2. **Coverage gates** (policy in [`.ci/coverage_config.lua`](.ci/coverage_config.lua), tool in [`.ci/fork/coverage.lua`](.ci/fork/coverage.lua)). PRs and pushes to `main` keep the native builds and run unit suites selected from the complete change range. Default local/manual commands and release candidates run full unit tests. Emulator integration scenarios run only for release candidates, including manual validation with `publish=false`.

   | Gate | PR / main CI | Fork release candidate |
   |---|---|---|
   | Changed executable Lua lines, unit tests | ≥ **80%** | ≥ **80%** |
   | Changed executable Lua lines, unit + integration | Unmeasured | ≥ **90%** |
   | Overall coverage ratchet (± 0.1 pp noise allowance) | Unmeasured | Separate full unit and combined coverage against their real measured ancestors |
   | Fork-owned modules ([`.ci/owned-modules.txt`](.ci/owned-modules.txt)) | Unmeasured | Combined tests: each ≥ **80%**, **85%** from 2026-11-24, **90%** from 2026-12-22 |
   | Dated overall unit targets | Unmeasured | ≥ **36.47%** from 2026-11-24, ≥ **41.47%** from 2026-12-22 |

   - CI selects suites through `.ci/fork/select_tests.py`, using the tested PR merge ref's first parent or the main push's `before` commit. Both base/head dependency graphs are used for deletions and renames. Literal `require`, protected require, plugin loads and simple string aliases form conservative reverse dependencies. Shared framework, native/build changes, unknown dynamic loaders or no proven affected suite retain full UT. Invalid Git/parse results fail instead of passing with an empty set. The `unit-selection.json` artifact records exact SHAs, suites and reasons. Base unit tests may be skipped only for a selected change whose base gitlink is unchanged; full fallback and releases run both groups.
   - Selection can remain broad: on `8e9a159e`, independent `frontend/random.lua` and `frontend/ui/plugin/switch_plugin.lua` changes select 1/142 front suites, while many UI/plugin changes select 139/142 through Device/ReaderUI/PluginLoader dependencies. These are dependency counts, not speed benchmarks. No dependency edge is removed to force a smaller set.
   - A release's combined diff spans **all changes since its previous measured combined ancestor**, excluding the candidate's own previous record for the diff; the overall ratchet also includes any previous real measurement of that same candidate. New daily unit records cannot shorten that interval or supply a combined baseline. KOReader publication fails if no real combined baseline exists. The exact `base` gitlink is checked independently using the candidate emulator's base unit and integration statistics; both artifacts carry the exact base SHA. Its first combined measurement checks the complete fork diff and reports the ratchet as unestablished.
   - Ordinary CI uses `mode=diff`: whole unit/combined and module metrics are `null`, including a conservative full-suite fallback. It does not publish coverage history or launch a background full-suite measurement. The publisher rejects diff results before any history write; ancestor lookup also ignores them. Only real full measurements update `baseline-unit.json`, `baseline.json` and badges on the [`coverage`](../../tree/coverage) branch. Existing full-unit backfill commands remain available.
   - Fork-owned modules retain their `fork`, `func:` and `file` scopes. New modules are included automatically. The dated unit targets and per-file plan remain in [doc/coverage-plan.md](doc/coverage-plan.md).
3. **All CI checks green** (required by the branch protection of `main`):
   - **Lint**: upstream's lint;
   - **Build and unit tests**: emulator build, selected front suites (base & front full on fallback), Kindle HF / PW2 builds;
   - **Coverage**: unit coverage gates, and **Tests policy**.

   The review gate reads the required contexts from branch protection. Integration tests are a release gate, so merging code does not wait for them.
4. **Test evidence in the description**: what you tested and how, and which integration scenario covers the change (see the PR template). For performance or memory changes, give before/after numbers (the integration scenarios' metrics are in the job summary and the `integration-results` artifact).

## Review and merge

Every PR to `main` is reviewed by the AI reviewer CodeRabbit and evaluated by the *Review gate*
workflow, which keeps a checklist comment on the PR. There is no human gate: the gate approves and enables auto-merge
(merge commit) when, on the head commit, all required checks passed (coverage gates included), CodeRabbit reviewed it
and does not request changes, every review thread is resolved, and the PR is not a draft and has no `do-not-merge` label.
Regressions are fixed forward. (Exception: an upstream sync PR opened by github-actions when `SYNC_TOKEN` is not
configured cannot be approved or auto-merged by the gate; the owner merges it.) AI comments flagged as potential issues / bugs must be fixed or answered with a
justification before resolving them. Details: [REVIEW_POLICY.md](REVIEW_POLICY.md).

所有合入 `main` 的 PR 由 AI（CodeRabbit）审查并经 *Review gate* 评估，不设人工关卡：最新提交上
必需检查全部通过（含覆盖率门禁）、AI 已审查且没有要求修改、所有审查对话已解决、非草稿且无 `do-not-merge` 时，网关自动批准
并开启自动合并（merge commit），出了回归就向前修复（例外：未配置 `SYNC_TOKEN` 时由 github-actions 创建的上游同步 PR，网关不能批准也不会自动合并，
由所有者合并）。AI 标出的潜在问题 / bug 必须修复或回复理由后才能解决对话。
详见 [REVIEW_POLICY.md](REVIEW_POLICY.md)。

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

- Push a tag `vYYYY.MM.qN` (e.g. `v2026.10.q1`; no `-`: `tools/describe.sh` and the version parsing expect `vYYYY.MM[.P]` before any `-`) on a commit of `main`: the *Fork release* workflow builds the Kindle packages (kindlehf, kindlepw2), the x86_64 emulator and the Lua overlays for upstream stable releases, runs the real integration budgets and coverage pass, enforces KOReader and exact-base full unit/combined coverage, and publishes a GitHub release.
- The rolling `nightly` prerelease is rebuilt from `main` daily when it changed (or manually: run *Fork release* on `main`). Its assets have stable names, e.g. `koreader-emulator-x86_64-latest.tar.xz`.

Release publication requires the emulator, Kindle builds, real integration tests and both coverage gates to succeed. `workflow_dispatch` with `force=true` and `publish=false` validates the current `main` candidate without moving tags, publishing assets, or writing either repository's coverage history. It retains the main ancestry restriction. Formal publication first records exact-base coverage using `SYNC_TOKEN`, scoped to that publication step; missing credentials or a failed history write stop publication before release assets or tags change. Lua overlays remain best effort across upstream versions: each overlay must pass its own real stable-runtime integration suite before its artifact is uploaded; a failed overlay is omitted and reported in the release notes.
