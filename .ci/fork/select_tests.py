#!/usr/bin/env python3
"""Conservative front UT selection from exact base/head Git trees; no Lua executes."""
import argparse
from collections import defaultdict, deque
import json
from pathlib import Path
import re
import subprocess
import sys


class SelectionError(ValueError):
    pass


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args])


def revision(repo, ref):
    return git(repo, "rev-parse", "--verify", ref + "^{commit}").decode().strip()


def tree(repo, ref):
    entries = []
    for entry in git(repo, "ls-tree", "-rz", "--full-tree", ref).split(b"\0"):
        if not entry:
            continue
        metadata, name = entry.split(b"\t", 1)
        kind, oid = metadata.decode().split()[1:]
        path = name.decode()
        if kind == "blob" and path.endswith(".lua") and (
                path.startswith(("frontend/", "plugins/", "spec/unit/")) or "/" not in path):
            entries.append((path, oid))
    data = subprocess.check_output(["git", "-C", str(repo), "cat-file", "--batch"],
                                   input="".join(oid + "\n" for _, oid in entries).encode())
    files, offset = {}, 0
    for path, oid in entries:
        end = data.index(b"\n", offset)
        header = data[offset:end].decode().split()
        if header[:2] != [oid, "blob"]:
            raise SelectionError("invalid Git blob response")
        size = int(header[2])
        files[path] = data[end + 1:end + 1 + size].decode("utf-8")
        offset = end + 2 + size
    return files


def tokens(source):
    """Keep strings indivisible; never infer dependencies from comments."""
    result, i = [], 0
    long_pattern = re.compile(r"\[(=*)\[")
    word_pattern = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
    while i < len(source):
        if source[i].isspace():
            i += 1
            continue
        comment = source.startswith("--", i)
        if comment:
            i += 2
        long = long_pattern.match(source, i)
        if long:
            start, ender = i + len(long[0]), "]" + long[1] + "]"
            end = source.find(ender, start)
            if end < 0:
                raise SelectionError("unterminated Lua long string/comment")
            if not comment:
                result.append(("string", source[start:end]))
            i = end + len(ender)
            continue
        if comment:
            end = source.find("\n", i)
            i = len(source) if end < 0 else end + 1
            continue
        char = source[i]
        if char in "\"'":
            end, value = i + 1, []
            while end < len(source) and source[end] != char:
                if source[end] == "\\":
                    end += 1
                    if end >= len(source):
                        raise SelectionError("unterminated Lua escape")
                    if source[end] not in "\\\"'":
                        value.append("\\")
                value.append(source[end])
                end += 1
            if end == len(source):
                raise SelectionError("unterminated Lua string")
            result.append(("string", "".join(value)))
            i = end + 1
            continue
        word = word_pattern.match(source, i)
        if word:
            result.append(("name", word[0]))
            i += len(word[0])
        elif source.startswith("..", i):
            result.append(("symbol", ".."))
            i += 2
        else:
            result.append(("symbol", char))
            i += 1
    return result


# Existing sandbox/data loaders read generated settings/exports, not tracked modules.
DATA_LOADERS = {"frontend/luadata.lua", "frontend/persist.lua", "frontend/ui/data/onetime_migration.lua",
                "spec/unit/readerannotation_spec.lua", "spec/unit/docsettings_locations_spec.lua",
                "frontend/apps/reader/modules/readerdictionary.lua", "frontend/device/input.lua",
                "frontend/device/thirdparty.lua", "frontend/docsettings.lua", "frontend/luadefaults.lua",
                "frontend/luasettings.lua", "frontend/readhistory.lua", "frontend/userpatch.lua",
                "plugins/calibre.koplugin/extensions.lua", "plugins/newsdownloader.koplugin/main.lua",
                "plugins/statistics.koplugin/main.lua"}
SHARED = {"reader.lua", "setupkoenv.lua", "defaults.lua", "datastorage.lua", "spec/unit/commonrequire.lua",
          "frontend/device.lua", "frontend/pluginloader.lua", "frontend/ui/uimanager.lua", "frontend/ui/time.lua",
          "frontend/util.lua", "frontend/luasettings.lua", "frontend/luadefaults.lua", "frontend/logger.lua"}
PREFIX_LOADERS = {
    ("frontend/ui/menusorter.lua", "dofile"): "frontend/ui/elements/",
    ("frontend/ui/elements/menu_keyboard_layout.lua", "require"): "frontend/ui/data/keyboardlayouts/",
    ("frontend/ui/widget/virtualkeyboard.lua", "require"): "frontend/ui/data/keyboardlayouts/",
    ("frontend/ui/network/manager.lua", "require"): "frontend/ui/network/",
    ("plugins/externalkeyboard.koplugin/main.lua", "loadfile"): "plugins/externalkeyboard.koplugin/",
    ("plugins/externalkeyboard.koplugin/keyboard_layout.lua", "loadfile"): "plugins/externalkeyboard.koplugin/",
    ("plugins/cloudstorage.koplugin/main.lua", "dofile"): "plugins/cloudstorage.koplugin/providers/",
}
# A change to a classified dynamic loader requires full UT; its old data/directory
# scope must never silently authorize a newly edited loader.
SHARED |= DATA_LOADERS | {path for path, _ in PREFIX_LOADERS}


def graph(files):
    edges, unknown = defaultdict(set), []
    plugin_roots = {"/".join(p.split("/")[:2]) for p in files if p.startswith("plugins/")}
    roots = ["", "frontend/", "spec/unit/"] + [p + "/" for p in sorted(plugin_roots)]

    def modules(value):
        value = value.replace(".", "/")
        return {r + value + s for r in roots for s in (".lua", "/init.lua") if r + value + s in files}

    for path, source in files.items():
        ts, aliases, opaque = tokens(source), defaultdict(set), set()
        for i in range(len(ts) - 2):
            if ts[i][0] == "name" and ts[i + 1][1] == "=":
                if ts[i + 2][0] == "string" and (i + 3 == len(ts) or ts[i + 3][1] != ".."):
                    aliases[ts[i][1]].add(ts[i + 2][1])
                else:
                    opaque.add(ts[i][1])
        for i, (kind, loader) in enumerate(ts):
            if kind != "name":
                continue
            j = i + 1
            if loader == "pcall" and ts[j:j + 1] == [("symbol", "(")]:
                if j + 2 < len(ts) and ts[j + 1][1] in {"require", "dofile", "loadfile"} and ts[j + 2][1] == ",":
                    loader, j = ts[j + 1][1], j + 3
                else:
                    continue
            elif loader in {"reload", "unload", "replace"} and i >= 2 and ts[i - 2:i] == [("name", "package"), ("symbol", ".")]:
                loader = "require"
            elif loader not in {"require", "dofile", "loadfile", "load_plugin"}:
                continue
            elif i and ts[i - 1][1] in {"function", ".", ":"}:
                continue
            elif ts[j:j + 1] != [("symbol", "(")] and (j >= len(ts) or ts[j][0] != "string"):
                if i and ts[i - 1][1] == "(" and i >= 2 and ts[i - 2][1] == "pcall":
                    continue
                unknown.append(path + ": indirect loader reference")
                continue
            if ts[j:j + 1] == [("symbol", "(")]:
                j += 1
            if j >= len(ts):
                raise SelectionError("missing loader argument")
            arg = ts[j]
            values = {arg[1]} if arg[0] == "string" else (set() if arg[1] in opaque else aliases.get(arg[1], set()))
            if j + 1 < len(ts) and ts[j + 1][1] in {"..", ".", "[", "("}:
                values = set()
            if not values:
                if path == "spec/unit/commonrequire.lua" and loader in {"require", "load_plugin"}:
                    # The helper's package.reload/load_plugin calls are resolved at each caller.
                    continue
                if path == "frontend/pluginloader.lua" and loader == "dofile":
                    edges[path].update(p for p in files if p.startswith("plugins/"))
                    continue
                if path in DATA_LOADERS and loader in {"dofile", "loadfile"}:
                    continue
                if (path, loader) in PREFIX_LOADERS:
                    edges[path].update(p for p in files if p.startswith(PREFIX_LOADERS[path, loader]))
                    continue
                unknown.append(path + ": dynamic " + loader)
                continue
            for value in values:
                if "\\" in value:
                    unknown.append(path + ": escaped loader path")
                elif loader == "require":
                    edges[path].update(modules(value))
                elif loader == "load_plugin":
                    root = "plugins/" + value.removesuffix(".koplugin") + ".koplugin/"
                    edges[path].update(p for p in files if p.startswith(root))
                elif value in files:
                    edges[path].add(value)
                elif not value.startswith(("spec/", "test/")):
                    unknown.append(path + ": unresolved " + loader)
    return edges, sorted(set(unknown))


def unrelated(path):
    return (path.startswith(("doc/", "spec/integration/"))
            or path == "tools/run_integration_tests.sh"
            or (path.endswith((".md", ".rst")) and ("/" not in path or path.startswith(".github/"))))


def validate_none(repo, manifest):
    base, head = manifest.get("base_sha"), manifest.get("head_sha")
    if (manifest.get("mode") != "none" or manifest.get("tests") != [] or not isinstance(base, str)
            or head != revision(repo, "HEAD") or git(repo, "merge-base", base, head).decode().strip() != base):
        raise SelectionError("invalid empty selection")
    changed = sorted(p.decode() for p in git(repo, "diff", "--name-only", "--no-renames", "-z", base, head).split(b"\0") if p)
    if manifest.get("changed_files") != changed or not all(unrelated(p) for p in changed):
        raise SelectionError("empty selection contains production/unit/framework changes")


def select(repo, base=None, head=None):
    if bool(base) != bool(head):
        raise SelectionError("both base and head are required")
    actual = revision(repo, head or "HEAD")
    current = tree(repo, actual)
    suites = sorted(p for p in current if p.startswith("spec/unit/") and p.endswith("_spec.lua"))
    if not suites:
        raise SelectionError("no front suites in the measured tree")
    result = {"schema_version": 1, "base_sha": None, "head_sha": actual, "mode": "full",
              "reasons": ["default full unit tests"], "tests": suites, "total_tests": len(suites), "changed_files": [], "base_unit_tests": "full"}
    if base is None:
        return result
    old = revision(repo, base)
    if git(repo, "merge-base", old, actual).decode().strip() != old:
        raise SelectionError("base must be an ancestor of head")
    result["base_sha"] = old
    changed = {p.decode() for p in git(repo, "diff", "--name-only", "--no-renames", "-z", old, actual).split(b"\0") if p}
    result["changed_files"] = sorted(changed)
    if all(unrelated(path) for path in changed):
        result.update(mode="none", tests=[], reasons=["no production, unit or framework changes"],
                      base_unit_tests="unchanged_skipped")
        return result
    for path in sorted(changed):
        if unrelated(path):
            continue
        if path in SHARED or not path.endswith(".lua") or not path.startswith(("frontend/", "plugins/", "spec/unit/")):
            result["reasons"] = ["shared or unclassified change: " + path]
            return result
    before, old_unknown = graph(tree(repo, old))
    after, new_unknown = graph(current)
    if old_unknown or new_unknown:
        result["reasons"] = ["unclassified loader: " + (old_unknown + new_unknown)[0]]
        return result
    reverse = defaultdict(set)
    for edges in (before, after):
        for consumer, dependencies in edges.items():
            for dependency in dependencies:
                reverse[dependency].add(consumer)
    affected, queue = set(changed), deque(changed)
    while queue:
        for consumer in reverse[queue.popleft()]:
            if consumer not in affected:
                affected.add(consumer)
                queue.append(consumer)
    selected = sorted(set(suites) & affected)
    if not selected:
        result["reasons"] = ["no proven affected suite; retain full unit tests"]
        return result
    if any(not re.fullmatch(r"spec/unit/[A-Za-z0-9_]+_spec\.lua", p) for p in selected):
        result["reasons"] = ["suite name requires the full runner"]
        return result
    result.update(mode="selected", reasons=["changed modules and reverse dependencies in base and head"], tests=selected,
                  base_unit_tests="unchanged_skipped")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--base")
    parser.add_argument("--head")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        text = json.dumps(select(args.repo, args.base, args.head), indent=2) + "\n"
        if args.output:
            args.output.write_text(text)
        else:
            sys.stdout.write(text)
    except (SelectionError, subprocess.CalledProcessError, UnicodeError) as error:
        print("unit selection failed: " + type(error).__name__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
