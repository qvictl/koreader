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
   - unit tests in `spec/unit/` (busted, run with `make testfront`), and/or
   - emulator integration scenarios in `spec/integration/scenarios/` (see [spec/integration/README.md](spec/integration/README.md)), for anything that involves the UI, documents, dictionaries, subprocesses, memory or timing.

   The required **Tests policy** check enforces this. Only a maintainer can waive it, by applying the `no-tests-needed` label (e.g. for a pure refactoring already covered by existing tests, or a change that can't be tested in the emulator); say why in the PR.
2. **Diff coverage.** At least **70%** of the changed executable Lua lines must be run by the unit + integration tests (luacov). The required **Diff coverage** check reports it on the PR (comment and job summary), with the lines not covered.
3. **All CI checks green** (required by the branch protection of `main`):
   - **Lint**: upstream's lint (`.ci/check.sh`: luacheck, shellcheck/shfmt, unscaled sizes, gettext…);
   - **Build and unit tests**: emulator build, base & front unit tests, Kindle HF / PW2 builds;
   - **Integration tests**: the emulator integration scenarios, including their memory and latency budgets;
   - **Diff coverage** and **Tests policy** (see above).
4. **Test evidence in the description**: what you tested and how (see the PR template). For performance or memory changes, give before/after numbers (the integration scenarios' metrics are in the job summary and the `integration-results` artifact).

## Running the tests locally

```sh
./kodev build                                     # build the emulator (or: make)
make testfront                                    # unit tests (front)
./tools/run_integration_tests.sh                  # integration scenarios (headless, SDL dummy driver)
./tools/run_integration_tests.sh dictionary       # only the scenarios whose name contains "dictionary"
./tools/run_integration_tests.sh --coverage       # with luacov (stats in integration-results/)
```

## Upstream

Changes made here are **not** submitted upstream. Upstream is merged weekly into `main` through a PR (`sync/upstream-<date>`); if a merge conflicts, an "Upstream sync conflict" issue is opened listing the conflicting files, to be resolved by hand. If upstream can no longer be merged cleanly, the fork continues independently.

## Releases

- Push a tag `vYYYY.MM-qN` (e.g. `v2026.10-q1`) on a commit of `main`: the *Fork release* workflow builds the Kindle packages (kindlehf, kindlepw2), the x86_64 emulator and the Lua overlays for upstream stable releases, runs the integration tests, and publishes a GitHub release.
- The rolling `nightly` prerelease is rebuilt from `main` daily when it changed (or manually: run *Fork release* on `main`). Its assets have stable names, e.g. `koreader-emulator-x86_64-latest.tar.xz`.
