#!/usr/bin/env bash
# Runs the emulator integration test scenarios (spec/integration/scenarios/*.lua).
#
# Each scenario runs in its own, real KOReader emulator process, headless (SDL dummy
# video driver by default), with an isolated KO_HOME (settings, cache, history), the
# generated fixtures (books & dictionaries), and the driver (spec/integration/driver.lua)
# loaded as a user patch. See spec/integration/README.md.
#
# Exit code: 0 if every scenario passed, 1 otherwise.

set -eo pipefail

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [SCENARIO_FILTER…]

Options:
  -k, --kodir DIR         KOReader install directory to test
                          (default: \$KODIR or koreader-emulator-x86_64-linux-gnu/koreader)
  -o, --output DIR        output directory (default: integration-results)
  -c, --coverage          collect luacov statistics (budgets are then only reported)
      --no-budgets        only report budget violations
      --budget-scale X    multiply every budget by X (default: \$IT_BUDGET_SCALE or 1)
  -t, --timeout SEC       override every scenario's timeout
  -r, --repeat N          run each scenario N times (to check for flakiness)
  -s, --skip STRING       skip scenarios whose file name contains STRING (repeatable)
  -l, --list              list scenarios and exit
  -h, --help              show this help

SCENARIO_FILTER: only run scenarios whose file name contains one of these strings.
EOF
}

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC_DIR="${SRC_DIR}/spec/integration"
KODIR="${KODIR:-}"
OUT_DIR="integration-results"
COVERAGE=''
NO_BUDGETS=''
BUDGET_SCALE="${IT_BUDGET_SCALE:-1}"
TIMEOUT=''
REPEAT=1
LIST=''
FILTERS=()
SKIPS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -k | --kodir)
            KODIR="$2"
            shift 2
            ;;
        -o | --output)
            OUT_DIR="$2"
            shift 2
            ;;
        -c | --coverage)
            COVERAGE=1
            shift
            ;;
        --no-budgets)
            NO_BUDGETS=1
            shift
            ;;
        --budget-scale)
            BUDGET_SCALE="$2"
            shift 2
            ;;
        -t | --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -r | --repeat)
            REPEAT="$2"
            shift 2
            ;;
        -s | --skip)
            SKIPS+=("$2")
            shift 2
            ;;
        -l | --list)
            LIST=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            echo "unknown option: $1" 1>&2
            usage 1>&2
            exit 2
            ;;
        *)
            FILTERS+=("$1")
            shift
            ;;
    esac
done

# Scenarios.
scenarios=()
for f in "${SPEC_DIR}"/scenarios/*.lua; do
    name="$(basename "${f}" .lua)"
    if [[ ${#FILTERS[@]} -gt 0 ]]; then
        keep=''
        for pat in "${FILTERS[@]}"; do
            [[ "${name}" == *"${pat}"* ]] && keep=1
        done
        [[ -n "${keep}" ]] || continue
    fi
    for pat in "${SKIPS[@]}"; do
        [[ "${name}" != *"${pat}"* ]] || continue 2
    done
    scenarios+=("${f}")
done
if [[ -n "${LIST}" ]]; then
    printf '%s\n' "${scenarios[@]##*/}"
    exit 0
fi
if [[ ${#scenarios[@]} -eq 0 ]]; then
    echo "no scenario matches: ${FILTERS[*]}" 1>&2
    exit 2
fi

# KOReader to test.
if [[ -z "${KODIR}" ]]; then
    KODIR="${SRC_DIR}/koreader-emulator-x86_64-linux-gnu/koreader"
fi
KODIR="$(cd "${KODIR}" && pwd)"
if [[ ! -x "${KODIR}/luajit" ]] || [[ ! -r "${KODIR}/reader.lua" ]]; then
    echo "not a KOReader install directory: ${KODIR}" 1>&2
    exit 2
fi

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
rm -rf "${OUT_DIR}"/{homes,results,logs,coverage,fixtures}
mkdir -p "${OUT_DIR}"/{homes,results,logs}
[[ -z "${COVERAGE}" ]] || mkdir -p "${OUT_DIR}/coverage"

echo "KOReader: ${KODIR} ($(cat "${KODIR}/git-rev" 2>/dev/null || echo '?'))"
echo "Output:   ${OUT_DIR}"

# Fixtures.
FIXTURES="${OUT_DIR}/fixtures"
python3 "${SPEC_DIR}/fixtures/make_fixtures.py" "${FIXTURES}"

lua_quote() {
    # Lua long string literal (paths have no "]]").
    printf '[[%s]]' "$1"
}

coverage_boot() {
    local statsfile="$1"
    cat <<EOF
package.path = "spec/rocks/share/lua/5.1/?.lua;spec/rocks/share/lua/5.1/?/init.lua;" .. package.path
package.cpath = "spec/rocks/lib/lua/5.1/?.so;" .. package.cpath
local ok, runner = pcall(require, "luacov.runner")
if ok then
    runner.init({
        statsfile = $(lua_quote "${statsfile}"),
        include = { "frontend/.*$", "plugins/.*$", "ffi/.*$" },
        exclude = { "luacov.*$", "ffi/.*_h$", "spec/.*$" },
        runreport = false,
        deletestats = false,
    })
else
    io.stderr:write("luacov not available: ", tostring(runner), "\n")
end
EOF
}

run_scenario() {
    local file="$1" run_name="$2"
    local home="${OUT_DIR}/homes/${run_name}"
    local result="${OUT_DIR}/results/${run_name}.json"
    local log="${OUT_DIR}/logs/${run_name}.log"
    rm -rf "${home}"
    mkdir -p "${home}/patches" "${home}/data"
    ln -s "${FIXTURES}/dict" "${home}/data/dict"
    cat >"${home}/settings.reader.lua" <<EOF
-- Generated by tools/run_integration_tests.sh
local t = {
    quickstart_shown_version = 999999999999,
    home_dir = $(lua_quote "${FIXTURES}/books"),
    lastdir = $(lua_quote "${FIXTURES}/books"),
    start_with = "filemanager",
    device_id = "integration-tests",
    color_rendering = false,
    document_metadata_folder = "dir",
    autoupdate_check = false,
}
local ok, scenario = pcall(dofile, $(lua_quote "${file}"))
if ok and type(scenario) == "table" and type(scenario.settings) == "table" then
    for k, v in pairs(scenario.settings) do
        t[k] = v
    end
end
return t
EOF
    cat >"${home}/patches/2-integration-driver.lua" <<EOF
-- Generated by tools/run_integration_tests.sh
dofile($(lua_quote "${SPEC_DIR}/driver.lua"))
EOF
    local scenario_timeout
    scenario_timeout="${TIMEOUT:-$(grep -m1 -oP '^\s*timeout\s*=\s*\K[0-9]+' "${file}" || echo 120)}"
    local cmd=(./luajit)
    if [[ -n "${COVERAGE}" ]]; then
        cmd+=(-e "$(coverage_boot "${OUT_DIR}/coverage/${run_name}.stats.out")")
    fi
    cmd+=(reader.lua)
    local start end code=0
    start="$(date +%s.%N)"
    (
        cd "${KODIR}"
        export KO_HOME="${home}"
        export IT_SCENARIO="${file}" IT_RESULT="${result}" IT_FIXTURES="${FIXTURES}"
        export IT_TIMEOUT="${TIMEOUT}" IT_BUDGET_SCALE="${BUDGET_SCALE}"
        export IT_NO_BUDGETS="${NO_BUDGETS}${COVERAGE}"
        export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}" SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}"
        export EMULATE_READER_W="${EMULATE_READER_W:-1072}" EMULATE_READER_H="${EMULATE_READER_H:-1448}"
        export EMULATE_READER_DPI="${EMULATE_READER_DPI:-300}"
        export KODEBUG="${KODEBUG:-}"
        exec timeout --kill-after=10 "$((scenario_timeout + 60))" "${cmd[@]}"
    ) >"${log}" 2>&1 || code=$?
    end="$(date +%s.%N)"
    awk -v code="${code}" -v start="${start}" -v end="${end}" \
        'BEGIN { printf "{\"exit_code\": %d, \"wall_s\": %.3f}\n", code, end - start }' >"${result%.json}.exit.json"
}

for file in "${scenarios[@]}"; do
    name="$(basename "${file}" .lua)"
    for ((i = 1; i <= REPEAT; i++)); do
        run_name="${name}"
        [[ "${REPEAT}" -eq 1 ]] || run_name="${name}.${i}"
        printf '%-40s ' "${run_name}"
        run_scenario "${file}" "${run_name}"
        python3 "${SPEC_DIR}/report.py" --one "${OUT_DIR}" "${run_name}" || true
    done
done

args=("${OUT_DIR}")
[[ -z "${COVERAGE}" ]] || args+=(--coverage "${KODIR}")
python3 "${SPEC_DIR}/report.py" "${args[@]}"
