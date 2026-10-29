#!/usr/bin/env bash
# Fork-owned CI tool: coverage gates & report (see .ci/fork/coverage.lua, CONTRIBUTING.md).
#
# Usage: coverage.sh ARTIFACTS_DIR
#
# ARTIFACTS_DIR holds the downloaded artifacts: a tarball with luajit & luacov
# (`koreader-emulator-x86_64.tar.xz`, or `base-luajit.tar.xz` for koreader-base), and the
# luacov stats: `*.stats.out` files under `unit-coverage*/` (unit tests) and
# `integration-coverage*/` (emulator integration tests).
#
# Environment: EVENT_NAME, PR_NUMBER, PR_BASE, PUSH_BEFORE, GH_TOKEN, GITHUB_REPOSITORY.
# Ordinary CI explicitly uses COVERAGE_MODE=diff: changed-unit80 only, no whole metrics/history.
# Default unit mode remains a full-unit measurement for manual/backfill callers.
# Release candidates enforce the combined gates too (COVERAGE_MODE=combined,
# EVENT_NAME=release, RELEASE_BASE=previous measured combined ancestor).
# The ratchet compares with the coverage recorded for the main commit the change is based on
# (or its nearest recorded ancestor), not with main's latest: see coverage_baseline.sh.
# Outputs (GITHUB_OUTPUT): ok=true|false; writes coverage-result.json (for the history).

set -eo pipefail

artifacts="$(cd "$1" && pwd)"
: "${GITHUB_OUTPUT:=/dev/stdout}" "${GITHUB_STEP_SUMMARY:=/dev/stdout}"
tmp="${RUNNER_TEMP:-/tmp}"
src="${PWD}"
mode="${COVERAGE_MODE:-unit}"
[[ "${mode}" == unit || "${mode}" == combined || "${mode}" == diff ]] || exit 2

enforce=diff,ratchet,unit
[[ "${mode}" != diff ]] || enforce='diff'
note=''
initial_push=false
case "${EVENT_NAME}" in
    release)
        [[ "${mode}" == combined ]] || exit 2
        enforce=diff,ratchet,owned,unit
        base="${RELEASE_BASE:?release coverage needs a measured combined baseline}"
        git merge-base --is-ancestor "${base}" HEAD
        note='(Release candidate: the entire change since the last measured combined ancestor is enforced.)'
        ;;
    pull_request)
        # The merge ref's first parent (pull_request.base.sha may be older).
        base="$("${src}/.ci/fork/coverage_baseline.sh" base pull_request)" || base="${PR_BASE}"
        ;;
    workflow_dispatch)
        if [[ -n "${PR_NUMBER}" ]]; then
            base="$(gh pr view "${PR_NUMBER}" --json baseRefOid --jq .baseRefOid)"
        else
            enforce=''
            base="$(git rev-parse HEAD~1)"
        fi
        ;;
    *)
        enforce=''
        base="${PUSH_BEFORE}"
        if [[ "${mode}" == diff ]]; then
            enforce='diff'
            if [[ "${EVENT_NAME}" == push && (-z "${base}" || "${base}" =~ ^0+$) ]]; then
                initial_push=true
                base="$(git hash-object -t tree /dev/null)"
            else
                git cat-file -e "${base}^{commit}" 2>/dev/null || {
                    echo 'invalid push change base' >&2
                    exit 2
                }
            fi
        elif [[ -z "${base}" ]] || [[ "${base}" =~ ^0+$ ]] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
            base="$(git rev-parse HEAD~1)"
        fi
        note='(Push: changed-line unit measurement only; no whole coverage record.)'

        ;;
esac
if [[ "${mode}" != diff ]]; then
    git fetch --quiet origin '+refs/heads/upstream:refs/remotes/origin/upstream' || true
    git fetch --quiet origin '+refs/heads/coverage:refs/remotes/origin/coverage'
    git fetch --quiet origin '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null || true
fi
if [[ "${initial_push}" != true ]]; then
    base="$(git merge-base "${base}" HEAD)"
fi
# The ratchet's base: the main commit the change is based on.
case "${EVENT_NAME}" in
    release) ratchet_base="$(git rev-parse HEAD)" ;;
    workflow_dispatch) ratchet_base="$("${src}/.ci/fork/coverage_baseline.sh" base workflow_dispatch)" || ratchet_base="${base}" ;;
    *) ratchet_base="${base}" ;;
esac
if [[ "${mode}" != diff ]] && [[ "${EVENT_NAME}" != release ]] && [[ -n "${enforce}" ]] && git rev-parse -q --verify origin/upstream >/dev/null; then
    all="$(git rev-list --count "${base}..HEAD")"
    own="$(git rev-list --count "${base}..HEAD" --not origin/upstream)"
    if [[ "${own}" != "${all}" ]]; then
        enforce=unit
        note="This change brings $((all - own)) upstream commit(s) (upstream sync): only the dated unit target is enforced; combined owned coverage is checked at release."
    fi
fi
echo "base: ${base}, ratchet base: ${ratchet_base}, head: $(git rev-parse HEAD), enforce: ${enforce:-none}"

selection="${artifacts}/unit-coverage/unit-selection.json"
if [[ "${mode}" == diff || "${EVENT_NAME}" == release || -f "${selection}" ]]; then
    allow_null_base="${initial_push}"
    [[ "${EVENT_NAME}" != workflow_dispatch ]] || allow_null_base=true
    jq -e --arg head "$(git rev-parse HEAD)" --arg base "${base}" --arg mode "${mode}" --argjson allow_null "${allow_null_base}" '
        .schema_version == 1 and .head_sha == $head and
        (.mode == "full" or .mode == "selected" or ($mode == "diff" and .mode == "none")) and
        (.tests | type == "array") and
        (if .mode == "none" then (.tests | length) == 0 else (.tests | length) > 0 end) and
        (if $mode != "diff" then .mode == "full" and (.tests | length) == .total_tests
         else (.base_sha == $base or ($allow_null and .mode == "full" and .base_sha == null and (.tests | length) == .total_tests)) end)
    ' "${selection}" >/dev/null || {
        echo 'missing/stale/incomplete unit selection proof' >&2
        exit 2
    }
fi
selection_none=false
if [[ "${mode}" == diff && "$(jq -r .mode "${selection}")" == none ]]; then
    python3 - "${selection}" "${src}" <<'PYTHON'
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(sys.argv[2]) / ".ci/fork"))
from select_tests import validate_none
validate_none(Path(sys.argv[2]), json.loads(Path(sys.argv[1]).read_text()))
PYTHON
    selection_none=true
fi

git diff -U0 "${base}" HEAD -- '*.lua' >"${tmp}/change.diff"
if [[ "${mode}" != diff ]] && git rev-parse -q --verify origin/upstream >/dev/null; then
    git diff -U0 "$(git merge-base HEAD origin/upstream)" HEAD -- '*.lua' >"${tmp}/fork.diff"
else
    : >"${tmp}/fork.diff"
fi
baseline=()
if [[ "${mode}" != diff ]]; then
    git show origin/coverage:history.jsonl >"${tmp}/coverage-history.jsonl" 2>/dev/null || : >"${tmp}/coverage-history.jsonl"
    if read -r bsha bpct bkind < <("${src}/.ci/fork/coverage_baseline.sh" lookup "${ratchet_base}" "${tmp}/coverage-history.jsonl" "${mode}"); then
        if [[ "${EVENT_NAME}" == release ]]; then
            label="main@${bsha:0:8} (previous actual combined measurement)"
        elif [[ "${bkind}" == exact ]]; then
            label="main@${bsha:0:8} (this change's base)"
        else
            label="main@${bsha:0:8} (nearest ancestor with coverage of base ${ratchet_base:0:8})"
        fi
        baseline=(--baseline-overall "${bpct}" --baseline-label "${label}")
    else
        [[ "${EVENT_NAME}" != release ]] || {
            echo "no measured combined baseline" >&2
            exit 1
        }
        baseline=(--baseline-label "no coverage recorded for base ${ratchet_base:0:8} or its ancestors")
    fi
    if [[ "${mode}" == combined ]]; then
        if read -r usha upct _ < <("${src}/.ci/fork/coverage_baseline.sh" lookup "${ratchet_base}" "${tmp}/coverage-history.jsonl" unit); then
            baseline+=(--baseline-unit "${upct}" --baseline-unit-label "main@${usha:0:8} (previous actual full unit measurement)")
            enforce+=,unit_ratchet
        else
            echo 'no previous real full-unit coverage baseline' >&2
            exit 1
        fi
    fi
fi
echo "ratchet baseline: ${baseline[*]}"
if [[ "${mode}" == diff ]]; then
    enforce='diff'
    note='Changed-line unit coverage only; full unit/combined metrics and targets are checked at release.'
fi

# luajit & luacov.
emu="${tmp}/coverage-luajit"
rm -rf "${emu}"
mkdir -p "${emu}"
tarball="$(find -L "${artifacts}" -name 'koreader-emulator-x86_64.tar.xz' -o -name 'base-luajit.tar.xz' | head -n1)"
tar -C "${emu}" -xJf "${tarball}" koreader/luajit koreader/spec/rocks 2>/dev/null || tar -C "${emu}" -xJf "${tarball}"
# Self-test of the gates' tool.
"${src}/.ci/fork/coverage_test.sh" "${emu}/koreader" || exit 2
stats=()
while read -r f; do
    case "${f}" in
        */integration-coverage*) stats+=(--integration "${f}") ;;
        *) stats+=(--unit "${f}") ;;
    esac
done < <(find -L "${artifacts}" -name '*.stats.out' | sort)
unit_count=0 integration_count=0
for ((i = 0; i < ${#stats[@]}; i += 2)); do
    [[ -s "${stats[i + 1]}" ]] || {
        echo "empty coverage stats" >&2
        exit 1
    }
    if [[ "${stats[i]}" == --unit ]]; then unit_count=$((unit_count + 1)); else integration_count=$((integration_count + 1)); fi
done
if [[ "${selection_none}" == true ]]; then
    [[ ${unit_count} -eq 0 && ${integration_count} -eq 0 ]] || {
        echo 'none selection unexpectedly has coverage stats' >&2
        exit 2
    }
else
    [[ ${unit_count} -gt 0 ]] || {
        echo 'missing unit coverage' >&2
        exit 1
    }
fi
if [[ "${mode}" == combined ]]; then
    [[ ${integration_count} -gt 0 ]] || {
        echo "missing integration coverage" >&2
        exit 1
    }
else
    [[ ${integration_count} -eq 0 ]] || {
        echo "unit mode cannot consume integration stats" >&2
        exit 1
    }
fi
echo "stats: ${stats[*]}"

md="${tmp}/coverage.md"
code=0
(
    cd "${emu}/koreader"
    ./luajit -e "package.path='spec/rocks/share/lua/5.1/?.lua;spec/rocks/share/lua/5.1/?/init.lua;'..package.path" \
        "${src}/.ci/fork/coverage.lua" --mode "${mode}" --config "${src}/.ci/coverage_config.lua" --src "${src}" \
        --diff "${tmp}/change.diff" --fork-diff "${tmp}/fork.diff" "${stats[@]}" "${baseline[@]}" \
        --enforce "${enforce:-none}" --note "${note}" --md "${md}" --json "${src}/coverage-result.json"
) || code=$?
if [[ ${code} -gt 1 ]]; then
    echo "coverage.lua failed (${code})" 1>&2
    exit "${code}"
fi
cat "${md}" >>"${GITHUB_STEP_SUMMARY}"
jq --arg commit "$(git rev-parse HEAD)" --arg event "${EVENT_NAME}" --arg diff_base "${base}" --arg ratchet_base "${bsha:-}" ' . + {commit: $commit, event: $event, diff_base: $diff_base, ratchet_base: (if $ratchet_base == "" then null else $ratchet_base end)}' \
    coverage-result.json >coverage-result.json.tmp && mv coverage-result.json.tmp coverage-result.json
echo "ok=$([[ ${code} -eq 0 ]] && echo true || echo false)" >>"${GITHUB_OUTPUT}"

# PR comment (best effort: the token is read-only for PRs from other repositories).
if [[ -n "${PR_NUMBER}" ]] && [[ -n "${GITHUB_REPOSITORY}" ]]; then
    body="$(cat "${md}")"
    id="$(gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" --paginate \
        --jq '.[] | select(.body | startswith("<!-- fork-coverage -->")) | .id' 2>/dev/null | tail -n1 || true)"
    if [[ -n "${id}" ]]; then
        gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${id}" -f body="${body}" >/dev/null || true
    else
        gh api -X POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" -f body="${body}" >/dev/null || true
    fi
fi
