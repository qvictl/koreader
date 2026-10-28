#!/usr/bin/env bash
# Paired runs must use the same frontend, book, fonts, settings and native dependencies.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
kodir='' output='' book='' font='Noto Sans CJK SC'
while (($#)); do
    case "$1" in
    --kodir)
        kodir=$2
        shift 2
        ;;
    --output)
        output=$2
        shift 2
        ;;
    --book)
        book=$2
        shift 2
        ;;
    --font)
        font=$2
        shift 2
        ;;
    *)
        echo "Usage: $0 --kodir DIR --output DIR --book FILE [--font NAME]" >&2
        exit 2
        ;;
    esac
done
[[ $(uname -s) == Linux && -n "${kodir}" && -n "${output}" && -f "${book}" ]] || {
    echo 'Linux, --kodir, --output and an existing --book are required.' >&2
    exit 2
}
mkdir -p "${output}"
output=$(realpath "${output}")
kodir=$(realpath "${kodir}")
book=$(realpath "${book}")
read -r -a freetype_flags <<<"$(pkg-config --cflags --libs freetype2)"
cc -shared -fPIC -O2 "${root}/tools/font_memory_probe.c" -Wl,--no-as-needed \
    "${freetype_flags[@]}" -ldl -o "${output}/font_memory_probe.so"
export FONT_BENCH_OUT="${output}" FONT_BENCH_BOOK="${book}" FONT_BENCH_FONT="${font}"
export FONT_PROBE_LOG="${output}/faces.tsv"
export LD_PRELOAD="${output}/font_memory_probe.so${LD_PRELOAD:+:${LD_PRELOAD}}"
exec bash "${root}/tools/run_integration_tests.sh" --kodir "${kodir}" --output "${output}/integration" 21_font_lifecycle
