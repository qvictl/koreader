#!/usr/bin/env python3
"""Run existing full UT by default; explicit validated selection only in CI."""
import argparse
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

from select_tests import SelectionError, git, revision, tree


def command(repo, selection, junit):
    options = ["-o", str(junit.resolve())]
    if selection is not None:
        manifest = json.loads(selection.read_text())
        all_tests = sorted(p for p in tree(repo, "HEAD") if p.startswith("spec/unit/") and p.endswith("_spec.lua"))
        tests = manifest.get("tests")
        if (manifest.get("schema_version") != 1 or manifest.get("head_sha") != revision(repo, "HEAD")
                or manifest.get("mode") not in {"full", "selected"} or not isinstance(tests, list)
                or not tests or tests != sorted(set(tests)) or not set(tests) <= set(all_tests)
                or manifest.get("total_tests") != len(all_tests)
                or any(not isinstance(p, str) for p in tests)
                or (manifest.get("mode") == "selected" and any(not re.fullmatch(r"spec/unit/[A-Za-z0-9_]+_spec\.lua", p) for p in tests))):
            raise SelectionError("invalid or stale selection manifest")
        if manifest["mode"] == "full" and (tests != all_tests or manifest.get("base_unit_tests") != "full"):
            raise SelectionError("full selection omitted suites")
        if manifest["mode"] == "selected":
            base = manifest.get("base_sha")
            if (not isinstance(base, str) or git(repo, "merge-base", base, "HEAD").decode().strip() != base
                    or git(repo, "diff", "--name-only", base, "HEAD", "--", "base")):
                raise SelectionError("selected plan cannot skip changed base units")
        if manifest["mode"] == "selected" and shutil.which("meson"):
            options += [Path(p).name.removesuffix("_spec.lua") for p in tests]
        elif manifest["mode"] == "selected":
            raise SelectionError("Meson disappeared after selection; generate a new full plan")
    return ["make", "--assume-old=all", "coverage-run", "T=" + shlex.join(options)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selection", type=Path)
    parser.add_argument("--junit", type=Path, required=True)
    args = parser.parse_args()
    try:
        return subprocess.call(command(Path.cwd(), args.selection, args.junit))
    except (SelectionError, ValueError, TypeError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print("unit runner failed: " + type(error).__name__, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
