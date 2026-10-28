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
[[ "${output}" != *[[:space:]:]* ]] || {
    echo "The output path cannot contain whitespace or colons (LD_PRELOAD): ${output}" >&2
    exit 2
}
book_dir=$(mktemp -d "${output}/book.XXXXXXXX")
cp --reflink=auto -- "${book}" "${book_dir}/$(basename "${book}")"
book="${book_dir}/$(basename "${book}")"
read -r -a freetype_flags <<<"$(pkg-config --cflags freetype2)"
export FONT_PROBE_FREETYPE="${kodir}/libs/libfreetype.so.6"
[[ -f "${FONT_PROBE_FREETYPE}" ]] || {
    echo 'The runtime FreeType shared library is missing.' >&2
    exit 2
}
cc -shared -fPIC -O2 "${root}/tools/font_memory_probe.c" "${freetype_flags[@]}" \
    -Wl,--no-as-needed "${FONT_PROBE_FREETYPE}" -ldl -o "${output}/font_memory_probe.so"
export FONT_BENCH_OUT="${output}" FONT_BENCH_BOOK="${book}" FONT_BENCH_FONT="${font}"
export FONT_PROBE_LOG="${output}/faces.tsv"
original_preload=${LD_PRELOAD-}
probe_preload="${output}/font_memory_probe.so${original_preload:+:${original_preload}}"
# Match the integration runner's library search order and verify that preloading
# the observer does not select a different FreeType than the unobserved runtime.
library_path() (
    cd "${kodir}"
    LD_PRELOAD="$1" LD_LIBRARY_PATH="${kodir}/libs:${LD_LIBRARY_PATH-}" ./luajit -e '
        require("setupkoenv")
        local ffi = require("ffi")
        ffi.cdef[[
            int FT_Init_FreeType(void **library);
            typedef struct {const char *name; void *base; const char *symbol; void *address;} FontProbeDlInfo;
            int dladdr(const void *address, FontProbeDlInfo *info);
        ]]
        local ft = ffi.loadlib("freetype", "6")
        local info = ffi.new("FontProbeDlInfo[1]")
        assert(ffi.C.dladdr(ffi.cast("const void *", ft.FT_Init_FreeType), info) ~= 0)
        print("FONT_LIBRARY_PATH=" .. ffi.string(info[0].name))
    '
)
library_path "${original_preload}" >"${output}/freetype-without-probe.log"
library_path "${probe_preload}" >"${output}/freetype-with-probe.log"
without=$(sed -n 's/^FONT_LIBRARY_PATH=//p' "${output}/freetype-without-probe.log")
with=$(sed -n 's/^FONT_LIBRARY_PATH=//p' "${output}/freetype-with-probe.log")
[[ -n "${without}" && -n "${with}" ]] || {
    echo 'Cannot identify the runtime FreeType.' >&2
    exit 1
}
# Paths are emitted relative to kodir by ffi.loadlib.
[[ $(cd "${kodir}" && realpath "${without}") == $(cd "${kodir}" && realpath "${with}") ]] || {
    echo 'The observer changed the loaded FreeType library; refusing to measure.' >&2
    exit 1
}
export LD_PRELOAD="${probe_preload}"
exec bash "${root}/tools/run_integration_tests.sh" --kodir "${kodir}" --output "${output}/integration" 21_font_lifecycle
