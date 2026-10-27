#!/usr/bin/env bash
# Fork-owned CI tool: publishes a fork release (see .github/workflows/fork_release.yml).
#
# Usage: publish_release.sh ASSETS_DIR
# Environment: CHANNEL (stable|nightly), TAG, GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA,
#              OVERLAY_RESULT (result of the overlay jobs).

set -eo pipefail

assets="$1"
: "${GITHUB_STEP_SUMMARY:=/dev/stdout}"
repo="${GITHUB_REPOSITORY:?}"
sha="${GITHUB_SHA:?}"
version="$(git describe --match='v[0-9]*' "${sha}" 2>/dev/null || git rev-parse --short "${sha}")"

cd "${assets}"
ls -l
shopt -s nullglob

# Name the assets.
suffix="${TAG}"
[[ "${CHANNEL}" != nightly ]] || suffix=latest
for f in koreader-kindle*.zip; do
    # koreader-kindlehf-v2026.10.q1.zip -> koreader-kindlehf-<suffix>.zip
    target="$(sed -E 's/^(koreader-kindle[a-z0-9-]*[a-z0-9])-v[0-9].*\.zip$/\1/' <<<"${f}")-${suffix}.zip"
    [[ "${f}" == "${target}" ]] || mv -v "${f}" "${target}"
done
if [[ -e koreader-emulator-x86_64.tar.xz ]]; then
    mv -v koreader-emulator-x86_64.tar.xz "koreader-emulator-x86_64-${suffix}.tar.xz"
fi
rm -f emulator-version.txt
files=(koreader-kindle*.zip koreader-emulator-x86_64-*.tar.xz koreader-lua-overlay-*.zip)
[[ ${#files[@]} -gt 0 ]] || {
    echo "no asset!" 1>&2
    exit 1
}
for required in "koreader-kindlehf-${suffix}.zip" "koreader-kindlepw2-${suffix}.zip" "koreader-emulator-x86_64-${suffix}.tar.xz"; do
    [[ -e "${required}" ]] || {
        echo "missing asset: ${required}" 1>&2
        exit 1
    }
done
cat >"build-info.json" <<EOF
{"channel": "${CHANNEL}", "tag": "${TAG}", "version": "${version}", "commit": "${sha}", "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
files+=(build-info.json)
sha256sum "${files[@]}" >SHA256SUMS
files+=(SHA256SUMS)

overlays=(koreader-lua-overlay-*.zip)
{
    if [[ "${CHANNEL}" == nightly ]]; then
        echo "Rolling nightly build of \`main\` — **${version}** (${sha})."
        echo
        echo "Stable asset names (for downstream CI): \`koreader-emulator-x86_64-latest.tar.xz\`, \`koreader-kindlehf-latest.zip\`, \`koreader-kindlepw2-latest.zip\`, \`koreader-lua-overlay-<upstream tag>-latest.zip\`."
    else
        echo "qvictl KOReader fork release **${TAG}** (${version}, ${sha})."
    fi
    echo
    echo "- \`koreader-kindlehf-*.zip\`, \`koreader-kindlepw2-*.zip\`: full KOReader packages for Kindle (install like upstream's)."
    echo "- \`koreader-emulator-x86_64-*.tar.xz\`: the x86_64 Linux emulator build (\`koreader/\` tree; run \`./luajit reader.lua\` in it), as used by the integration tests. It uses the system's SDL3: run it in the \`koreader/kobase:5.0.0-22.04\` docker image (or install SDL 3), headless with \`SDL_VIDEODRIVER=dummy\`."
    if [[ ${#overlays[@]} -gt 0 ]]; then
        echo "- \`koreader-lua-overlay-<upstream tag>-*.zip\`: the fork's Lua changes for devices running that upstream stable release (see README.txt inside)."
    fi
    if [[ "${OVERLAY_RESULT}" != success ]]; then
        echo
        echo "⚠️ Some Lua overlays could not be built (the fork's changes don't apply to that upstream release): see the workflow run."
    fi
    echo
    echo "Built by ${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID:-0}; every asset passed the emulator integration tests (overlays: on upstream's Linux package)."
} >notes.md

if [[ "${CHANNEL}" == nightly ]]; then
    # Move (or create) the `nightly` tag.
    if gh api "repos/${repo}/git/ref/tags/nightly" >/dev/null 2>&1; then
        gh api -X PATCH "repos/${repo}/git/refs/tags/nightly" -f sha="${sha}" -F force=true >/dev/null
    else
        gh api -X POST "repos/${repo}/git/refs" -f ref=refs/tags/nightly -f sha="${sha}" >/dev/null
    fi
    if gh release view nightly >/dev/null 2>&1; then
        gh release edit nightly --prerelease --title "Nightly (${version})" --notes-file notes.md >/dev/null
        # Drop assets that are not part of this build.
        mapfile -t old < <(gh release view nightly --json assets --jq '.assets[].name')
        for a in "${old[@]}"; do
            [[ " ${files[*]} " == *" ${a} "* ]] || gh release delete-asset -y nightly "${a}"
        done
    else
        gh release create nightly --prerelease --title "Nightly (${version})" --notes-file notes.md --target "${sha}" >/dev/null
    fi
    gh release upload --clobber nightly "${files[@]}"
else
    if gh release view "${TAG}" >/dev/null 2>&1; then
        gh release edit "${TAG}" --notes-file notes.md >/dev/null
    else
        gh release create "${TAG}" --verify-tag --title "${TAG}" --notes-file notes.md >/dev/null
    fi
    gh release upload --clobber "${TAG}" "${files[@]}"
fi
url="$(gh release view "${TAG}" --json url --jq .url)"
{
    echo "## Published ${url}"
    echo
    printf -- '- %s\n' "${files[@]}"
} >>"${GITHUB_STEP_SUMMARY}"
echo "${url}"
