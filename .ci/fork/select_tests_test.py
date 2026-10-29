#!/usr/bin/env python3
"""Offline Git fixtures for conservative UT dependency selection."""
from pathlib import Path
import os
import shlex
import textwrap
import subprocess
import sys
from unittest import mock
import json
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parent))
import run_unit_tests as runner
import select_tests as selector


class GitFixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "--quiet")
        self.git("config", "user.name", "test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.write("frontend/leaf.lua", "return {}\n")
        self.write("frontend/mid.lua", 'return require("leaf")\n')
        self.write("frontend/other.lua", "return {}\n")
        self.write("spec/unit/a_spec.lua", 'local mid = require "mid"\n')
        self.write("spec/unit/b_spec.lua", 'local other = require("other")\n')
        self.base = self.commit()

    def git(self, *args):
        return selector.git(self.repo, *args).decode().strip()

    def write(self, name, source):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def commit(self):
        self.git("add", "-A")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def choose(self):
        return selector.select(self.repo, self.base, self.commit())


class SelectionTests(GitFixture, unittest.TestCase):
    def test_default_is_full_and_refs_are_explicit(self):
        self.assertEqual(selector.select(self.repo)["mode"], "full")
        with self.assertRaises(selector.SelectionError):
            selector.select(self.repo, self.base)

    def test_reverse_dependencies_select_transitive_suite(self):
        self.write("frontend/leaf.lua", "return { changed = true }\n")
        result = self.choose()
        self.assertEqual(result["tests"], ["spec/unit/a_spec.lua"])
        self.assertEqual(result["mode"], "selected")
        self.assertEqual(result["total_tests"], 2)
        self.assertEqual(result["base_sha"], self.base)
        self.assertEqual(result["head_sha"], self.git("rev-parse", "HEAD"))

    def test_changed_and_new_specs_are_always_included(self):
        self.write("spec/unit/new_spec.lua", "describe('new', function() end)\n")
        self.write("spec/unit/b_spec.lua", 'local other = require("other") -- updated\n')
        self.assertEqual(self.choose()["tests"], ["spec/unit/b_spec.lua", "spec/unit/new_spec.lua"])

    def test_deleted_dependency_uses_old_graph(self):
        (self.repo / "frontend/leaf.lua").unlink()
        self.write("frontend/mid.lua", "return {}\n")
        self.assertEqual(self.choose()["tests"], ["spec/unit/a_spec.lua"])

    def test_rename_tracks_old_and_new_consumers(self):
        self.write("frontend/new.lua", (self.repo / "frontend/leaf.lua").read_text())
        (self.repo / "frontend/leaf.lua").unlink()
        self.write("spec/unit/b_spec.lua", 'local new = require("new")\n')
        result = self.choose()
        self.assertEqual(result["tests"], ["spec/unit/a_spec.lua", "spec/unit/b_spec.lua"])
        self.assertIn("frontend/leaf.lua", result["changed_files"])
        self.assertIn("frontend/new.lua", result["changed_files"])

    def test_pcall_and_literal_alias_and_package_reload(self):
        self.write("spec/unit/a_spec.lua", 'local MOD = "mid"; local mid = require(MOD); package.reload("leaf")\n')
        self.write("spec/unit/b_spec.lua", 'local ok, leaf = pcall(require, "leaf")\n')
        self.base = self.commit()
        self.write("frontend/leaf.lua", "return { changed = true }\n")
        self.assertEqual(self.choose()["tests"], ["spec/unit/a_spec.lua", "spec/unit/b_spec.lua"])

    def test_mutable_alias_cannot_hide_unknown_loader(self):
        self.write("spec/unit/b_spec.lua", 'local MOD = "other"; MOD = compute(); require(MOD)\n')
        self.base = self.commit()
        self.write("frontend/leaf.lua", "return { changed = true }\n")
        self.assertEqual(self.choose()["mode"], "full")

    def test_plugin_dofile_and_ambiguous_package_path_union(self):
        for name in ("one", "two"):
            self.write(f"plugins/{name}.koplugin/helper.lua", "return {}\n")
            self.write(f"plugins/{name}.koplugin/main.lua", 'return require("helper")\n')
        self.write("spec/unit/a_spec.lua", 'local one = dofile("plugins/one.koplugin/main.lua")\n')
        self.write("spec/unit/b_spec.lua", 'load_plugin("two.koplugin")\n')
        self.base = self.commit()
        self.write("plugins/one.koplugin/helper.lua", "return { changed = true }\n")
        self.assertEqual(self.choose()["tests"], ["spec/unit/a_spec.lua", "spec/unit/b_spec.lua"])

    def test_comments_and_long_strings_do_not_create_edges(self):
        self.write("spec/unit/b_spec.lua", '-- require("leaf")\n--[=[ require("leaf") ]=]\nlocal s = [[require("leaf")]]\n')
        self.base = self.commit()
        self.write("frontend/leaf.lua", "return { changed = true }\n")
        self.assertEqual(self.choose()["tests"], ["spec/unit/a_spec.lua"])

    def test_unknown_dynamic_loader_and_indirect_loader_fall_back(self):
        for source in ('require(dynamic_name)', 'local loader = require; loader(dynamic_name)'):
            self.write("spec/unit/b_spec.lua", source)
            self.assertEqual(self.choose()["mode"], "full")

    def test_shared_native_and_unknown_file_fall_back(self):
        for path in ("spec/unit/commonrequire.lua", "frontend/ui/uimanager.lua", "base", "Makefile", "test/sample.epub"):
            self.write(path, "changed")
            self.assertEqual(self.choose()["mode"], "full")

    def test_no_proven_suite_never_succeeds_with_empty_selection(self):
        self.write("frontend/unmapped.lua", "return {}\n")
        result = self.choose()
        self.assertEqual(result["mode"], "full")
        self.assertEqual(len(result["tests"]), 2)

    def test_parse_and_git_failures_do_not_return_a_selection(self):
        self.write("frontend/bad.lua", 'return "unterminated')
        with self.assertRaises(selector.SelectionError):
            self.choose()
        with self.assertRaises(subprocess.CalledProcessError):
            selector.select(self.repo, "missing-ref", self.base)

    def test_nonancestor_base_is_rejected(self):
        self.write("frontend/leaf.lua", "return { changed = true }\n")
        newer = self.commit()
        with self.assertRaises(selector.SelectionError):
            selector.select(self.repo, newer, self.base)

    def test_classified_dynamic_loader_changes_force_full(self):
        self.write("frontend/ui/widget/virtualkeyboard.lua", 'require("ui/data/keyboardlayouts/" .. layout)')
        self.assertEqual(self.choose()["mode"], "full")


class RunnerTests(GitFixture, unittest.TestCase):
    def test_full_is_default_and_selection_is_explicit(self):
        command = runner.command(self.repo, None, self.repo / "junit.xml")
        self.assertEqual(command[:3], ["make", "--assume-old=all", "coverage-run"])
        self.assertNotIn(" a", command[3])

    def test_selected_uses_exact_meson_suite_names(self):
        self.write("frontend/leaf.lua", "return { changed = true }\n")
        manifest = self.choose()
        path = self.repo / "selection.json"
        path.write_text(json.dumps(manifest))
        with mock.patch.object(runner.shutil, "which", return_value="/usr/bin/meson"):
            command = runner.command(self.repo, path, self.repo / "junit.xml")
        self.assertTrue(command[3].endswith(" a"))
        self.assertNotIn(" b", command[3])

    def test_missing_meson_after_selection_fails_instead_of_skipping_base_units(self):
        self.write("frontend/leaf.lua", "return { changed = true }\n")
        path = self.repo / "selection.json"
        path.write_text(json.dumps(self.choose()))
        with mock.patch.object(runner.shutil, "which", return_value=None), self.assertRaises(selector.SelectionError):
            runner.command(self.repo, path, self.repo / "junit.xml")

    def test_stale_empty_and_incomplete_full_manifest_fail(self):
        valid = selector.select(self.repo)
        path = self.repo / "selection.json"
        for update in ({"head_sha": "0" * 40}, {"tests": []}, {"tests": ["spec/unit/a_spec.lua"]}):
            path.write_text(json.dumps(dict(valid, **update)))
            with self.subTest(update=update), self.assertRaises(selector.SelectionError):
                runner.command(self.repo, path, self.repo / "junit.xml")


class WorkflowTests(GitFixture, unittest.TestCase):
    def run_step(self, base="", event="push", full="false"):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/fork_emulator.yml").read_text()
        block = workflow.split("      - name: Select affected front unit suites\n", 1)[1]
        script = textwrap.dedent(block.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
        bindir = self.repo / "test-bin"
        bindir.mkdir(exist_ok=True)
        python = bindir / "python3"
        python.write_text("#!/bin/bash\n"
                          'if [[ "$1" == .ci/fork/select_tests_test.py ]]; then exit 0; fi\n'
                          'if [[ "$1" == .ci/fork/select_tests.py ]]; then shift; exec '
                          + shlex.quote(sys.executable) + " " + shlex.quote(str(root / ".ci/fork/select_tests.py"))
                          + ' "$@"; fi\nexec ' + shlex.quote(sys.executable) + ' "$@"\n')
        python.chmod(0o755)
        meson = bindir / "meson"
        meson.write_text("#!/bin/sh\nexit 0\n")
        meson.chmod(0o755)
        env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"],
                   CHANGE_BASE=base, CHANGE_EVENT=event, FULL_RELEASE_UNITS=full,
                   GITHUB_OUTPUT=str(self.repo / "output.txt"))
        result = subprocess.run(["bash", "-eo", "pipefail", "-c", script], cwd=self.repo,
                                env=env, capture_output=True, text=True)
        path = self.repo / "unit-selection.json"
        return result.returncode, json.loads(path.read_text()) if path.exists() else None

    def test_release_forces_full_even_if_change_inputs_exist(self):
        code, manifest = self.run_step("invalid-ref", full="true")
        self.assertEqual(code, 0)
        self.assertEqual(manifest["mode"], "full")
        self.assertEqual(manifest["base_unit_tests"], "full")

    def test_manual_without_change_base_keeps_full(self):
        code, manifest = self.run_step(event="workflow_dispatch")
        self.assertEqual(code, 0)
        self.assertEqual(manifest["mode"], "full")

    def test_push_uses_before_even_when_origin_main_already_equals_head(self):
        self.write("frontend/leaf.lua", "return { changed = true }\n")
        head = self.commit()
        self.git("update-ref", "refs/remotes/origin/main", head)
        code, manifest = self.run_step(self.base)
        self.assertEqual(code, 0)
        self.assertEqual(manifest["tests"], ["spec/unit/a_spec.lua"])
        self.assertEqual(manifest["base_unit_tests"], "unchanged_skipped")

    def test_unknown_base_fails_before_any_manifest(self):
        code, manifest = self.run_step("missing-ref")
        self.assertNotEqual(code, 0)
        self.assertIsNone(manifest)

    def test_pr_merge_uses_actual_first_parent_for_complete_pr_range(self):
        self.git("checkout", "-qb", "feature", self.base)
        self.write("frontend/leaf.lua", "return { changed = true }\n")
        feature = self.commit()
        self.git("checkout", "-qb", "main", self.base)
        self.write("frontend/other.lua", "return { changed = true }\n")
        main = self.commit()
        self.git("merge", "--quiet", "--no-ff", "--no-edit", feature)
        code, manifest = self.run_step(self.base, event="pull_request")
        self.assertEqual(code, 0)
        self.assertEqual(manifest["base_sha"], main)
        self.assertEqual(manifest["tests"], ["spec/unit/a_spec.lua"])


if __name__ == "__main__":
    unittest.main()
