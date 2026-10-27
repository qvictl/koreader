#!/usr/bin/env bash
# Fork-owned CI tool: builds a "Lua overlay" zip, i.e. the fork's Lua (and launcher script)
# changes applied on top of an upstream KOReader release, for devices running that release.
#
# Usage: make_overlay.sh UPSTREAM_TAG BASE_REPO_DIR OUTPUT_DIR [SUFFIX]
#
#   UPSTREAM_TAG   upstream release the overlay is for (e.g. v2026.07.1)
#   BASE_REPO_DIR  a clone of qvictl/koreader-base with its `main` and `upstream` branches
#                  (as origin/main & origin/upstream) and upstream's history
#   OUTPUT_DIR     where to write koreader-lua-overlay-<TAG>[-SUFFIX].zip
#
# Run from a full clone of qvictl/koreader at the commit to release, with origin/upstream.
# The fork's changes are `git diff <merge-base with upstream> HEAD` (resp. for base), limited
# to Lua files and the Kindle launcher; they are applied with a 3-way merge onto the release's
# files, unless a `stable/<TAG>` branch exists (the fork's changes backported onto that
# release by hand): then its changes are used instead. Binaries (e.g. sdcv with the res/
# fix) are not part of the overlay.
#
# Exit code: 0 on success, 1 if the changes do not apply to that release.

set -eo pipefail

tag="$1"
base_repo="$(cd "$2" && pwd)"
out_dir="$3"
suffix="${4:+-$4}"
mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"
name="koreader-lua-overlay-${tag}${suffix}"
work="$(mktemp -d)"
trap 'git worktree remove --force "${work}/ko" >/dev/null 2>&1 || true; git -C "${base_repo}" worktree remove --force "${work}/base" >/dev/null 2>&1 || true; rm -rf "${work}"' EXIT

ko_paths=(frontend plugins reader.lua setupkoenv.lua datastorage.lua defaults.lua platform/kindle/koreader.sh)
ko_fork_base="$(git merge-base HEAD origin/upstream)"
git diff --binary "${ko_fork_base}" HEAD -- "${ko_paths[@]}" >"${work}/ko.diff"
base_head="$(git ls-tree HEAD base | awk '{print $3}')"
base_fork_base="$(git -C "${base_repo}" merge-base "${base_head}" origin/upstream)"
git -C "${base_repo}" diff --binary "${base_fork_base}" "${base_head}" -- 'ffi/*.lua' >"${work}/base.diff"

# Release trees. A `stable/<tag>` branch, if any, holds the fork's changes already backported
# onto that release (for when they don't apply automatically): use it as is.
release_base="$(git ls-tree "${tag}" base | awk '{print $3}')"
if git rev-parse -q --verify "refs/remotes/origin/stable/${tag}" >/dev/null; then
    echo "Using the stable/${tag} backport branch ($(git rev-parse --short refs/remotes/origin/stable/"${tag}"))"
    git worktree add --quiet --detach "${work}/ko" "refs/remotes/origin/stable/${tag}"
    : >"${work}/ko.diff"
else
    git worktree add --quiet --detach "${work}/ko" "${tag}"
fi
git -C "${base_repo}" worktree add --quiet --detach "${work}/base" "${release_base}"

failed=''
apply() {
    # $1: tree, $2: diff
    if [[ -s "$2" ]] && ! git -C "$1" apply --3way --whitespace=nowarn "$2"; then
        echo "ERROR: the fork's changes do not apply cleanly onto ${tag} ($1):" 1>&2
        git -C "$1" diff --name-only --diff-filter=U 1>&2 || true
        failed=1
    fi
}
apply "${work}/ko" "${work}/ko.diff"
apply "${work}/base" "${work}/base.diff"
if [[ -n "${failed}" ]]; then
    exit 1
fi

# Device layout: everything under koreader/, the Kindle launcher as koreader/koreader.sh.
dest() {
    case "$1" in
        platform/kindle/koreader.sh) echo "koreader/koreader.sh" ;;
        *) echo "koreader/$1" ;;
    esac
}
stage="${work}/${name}"
mkdir -p "${stage}/koreader" "${stage}/backup-original/koreader"
new_files=()
deleted_files=()
copy_changes() {
    # $1: tree, $2: tree-ish of the release's originals
    local status path
    while IFS=$'\t' read -r status path; do
        [[ -n "${path}" ]] || continue
        local d
        d="$(dest "${path}")"
        if [[ "${status}" == D ]]; then
            deleted_files+=("${d}")
            continue
        fi
        install -D -m 644 "$1/${path}" "${stage}/${d}"
        if git -C "$1" cat-file -e "$2:${path}" 2>/dev/null; then
            mkdir -p "$(dirname "${stage}/backup-original/${d}")"
            git -C "$1" show "$2:${path}" >"${stage}/backup-original/${d}"
        else
            new_files+=("${d}")
        fi
    done < <(git -C "$1" diff --name-status "$2" -- "${@:3}")
}
copy_changes "${work}/ko" "${tag}" "${ko_paths[@]}"
copy_changes "${work}/base" "${release_base}" ffi
if [[ -x "${stage}/koreader/koreader.sh" ]] || [[ -e "${stage}/koreader/koreader.sh" ]]; then
    chmod 755 "${stage}/koreader/koreader.sh"
fi

version="$(git describe --match='v[0-9]*' HEAD 2>/dev/null || git rev-parse --short HEAD)"
{
    echo "KOReader ${tag} Lua overlay - qvictl fork ${version} ($(git rev-parse --short=12 HEAD))"
    echo
    echo "For devices running the upstream KOReader ${tag} release: replaces the Lua files"
    echo "changed by the qvictl fork (https://github.com/qvictl/koreader) with their patched version."
    echo "Binaries are not included (e.g. sdcv's res/ directory fix needs the full fork package)."
    echo
    echo "Install: copy the \"koreader\" folder onto the device's KOReader parent folder"
    echo "         (on a Kindle: the root of the USB drive), merging/overwriting, then restart KOReader."
    echo "Revert:  copy \"backup-original/koreader\" the same way"
    if [[ ${#new_files[@]} -gt 0 ]]; then
        echo "         and delete these files, that are new in this overlay:"
        printf '           %s\n' "${new_files[@]}"
    fi
    if [[ ${#deleted_files[@]} -gt 0 ]]; then
        echo
        echo "Delete these files when installing (removed by the fork):"
        printf '  %s\n' "${deleted_files[@]}"
    fi
    echo
    echo "Files:"
    (cd "${stage}" && find koreader -type f | sort | sed 's/^/  /')
} >"${stage}/README.txt"

rm -f "${out_dir}/${name}.zip"
(cd "${work}" && zip -qr -X "${out_dir}/${name}.zip" "${name}")
echo "${out_dir}/${name}.zip"
