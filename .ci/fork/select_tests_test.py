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

    def test_docs_and_integration_only_are_explicit_none(self):
        self.write("README.md", "documentation")
        self.write("spec/integration/scenarios/example.lua", "return {}")
        result = self.choose()
        self.assertEqual(result["mode"], "none")
        self.assertEqual(result["tests"], [])
        selector.validate_none(self.repo, result)

    def test_forced_full_keeps_explicit_change_provenance(self):
        self.write("frontend/leaf.lua", "return { changed = true }")
        head = self.commit()
        result = selector.select(self.repo, self.base, head, force_full=True)
        self.assertEqual(result["mode"], "full")
        self.assertEqual(result["base_sha"], self.base)
        self.assertIn("frontend/leaf.lua", result["changed_files"])

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
        self.assertEqual(self.choose()["tests"], ["spec/unit/a_spec.lua", "spec/unit/b_spec.lua"])

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

    def test_only_changed_spec_runs_despite_its_dynamic_loader(self):
        for source in ('require(dynamic_name)', 'local loader = require; loader(dynamic_name)'):
            self.write("spec/unit/b_spec.lua", source)
            self.assertEqual(self.choose()["tests"], ["spec/unit/b_spec.lua"])

    def test_indirect_loaders_keep_both_existing_consumers(self):
        sources = [
            '_G.require("leaf")', '_G["require"]("leaf")',
            'local key = "require"; _G[key]("leaf")', 'getfenv().require("leaf")',
            'local env = getfenv(); env["require"]("leaf")',
            'local loader = require; loader("leaf")',
            'local key = "loadlib"; package[key]("leaf")',
            'package.loaders[1]("leaf")', 'package.searchers[1]("leaf")',
            'loadstring([[return require("leaf")]])()',
            'rawget(_G, "require")("leaf")', 'local env = _G; env.require("leaf")',
            'local key = "leaf"; package.loaded[key]()',
            'local key = "loader"; package.preload[key]("leaf")',
            'local loaded = package.loaded; loaded["leaf"]()', 'package.loaded.leaf()',
        ]
        for index, source in enumerate(sources):
            with self.subTest(source=source):
                self.write("spec/unit/b_spec.lua", source)
                self.base = self.commit()
                self.write("frontend/leaf.lua", "return { changed = %d }" % index)
                result = self.choose()
                self.assertEqual(result["tests"], ["spec/unit/a_spec.lua", "spec/unit/b_spec.lua"])

    def test_changed_runtime_unknown_loader_forces_full(self):
        self.write("frontend/mid.lua", '_G.require("leaf")')
        self.assertEqual(self.choose()["mode"], "full")

    def test_unknown_external_lua_cannot_hide_an_indirect_consumer(self):
        self.write("spec/unit/b_spec.lua", 'require("unknown_external")')
        self.base = self.commit()
        self.write("frontend/leaf.lua", "return { changed = true }")
        self.assertEqual(self.choose()["tests"], ["spec/unit/a_spec.lua", "spec/unit/b_spec.lua"])

    def test_generated_data_dofile_may_still_import_target(self):
        self.write("frontend/luasettings.lua", 'local ok, data = pcall(dofile, settings_path); return data')
        self.write("spec/unit/b_spec.lua", 'require("luasettings")')
        self.base = self.commit()
        self.write("frontend/leaf.lua", "return { changed = true }")
        self.assertEqual(self.choose()["tests"], ["spec/unit/a_spec.lua", "spec/unit/b_spec.lua"])

    def test_spec_only_does_not_expand_unrelated_opaque_consumers(self):
        self.write("spec/unit/b_spec.lua", '_G.require("leaf")')
        self.base = self.commit()
        self.write("spec/unit/a_spec.lua", 'require("mid") -- test changed')
        self.assertEqual(self.choose()["tests"], ["spec/unit/a_spec.lua"])

    def test_unreachable_opaque_module_does_not_expand_suites(self):
        self.write("vendor/unreachable.lua", '_G.require("leaf")')
        self.base = self.commit()
        self.write("frontend/leaf.lua", "return { changed = true }")
        self.assertEqual(self.choose()["tests"], ["spec/unit/a_spec.lua"])

    def test_internal_git_lua_outside_frontend_is_a_real_dependency(self):
        self.write("vendor/wrapper.lua", 'return require("leaf")')
        self.write("spec/unit/b_spec.lua", 'require("vendor/wrapper")')
        self.base = self.commit()
        self.write("frontend/leaf.lua", "return { changed = true }")
        self.assertEqual(self.choose()["tests"], ["spec/unit/a_spec.lua", "spec/unit/b_spec.lua"])

    def test_shared_native_and_unknown_file_fall_back(self):
        for path in ("spec/unit/commonrequire.lua", "frontend/ui/uimanager.lua", "base", "Makefile", "test/sample.epub"):
            with self.subTest(path=path):
                self.write(path, "changed")
                result = self.choose()
                self.assertEqual(result["mode"], "full")
                self.assertEqual(result["changed_files"], [path])
                self.assertEqual(result["reasons"], ["shared or unclassified change: " + path])
                self.base = self.git("rev-parse", "HEAD")

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

    def test_none_skips_make_and_cannot_hide_production_changes(self):
        self.write("README.md", "documentation")
        manifest = self.choose()
        path = self.repo / "selection.json"
        path.write_text(json.dumps(manifest))
        self.assertIsNone(runner.command(self.repo, path, self.repo / "junit.xml"))
        self.write("frontend/leaf.lua", "return { changed = true }")
        head = self.commit()
        manifest.update(head_sha=head, changed_files=["README.md", "frontend/leaf.lua"])
        path.write_text(json.dumps(manifest))
        with self.assertRaises(selector.SelectionError):
            runner.command(self.repo, path, self.repo / "junit.xml")

    def test_stale_empty_and_incomplete_full_manifest_fail(self):
        valid = selector.select(self.repo)
        path = self.repo / "selection.json"
        for update in ({"head_sha": "0" * 40}, {"tests": []}, {"tests": ["spec/unit/a_spec.lua"]}):
            path.write_text(json.dumps(dict(valid, **update)))
            with self.subTest(update=update), self.assertRaises(selector.SelectionError):
                runner.command(self.repo, path, self.repo / "junit.xml")


class WorkflowTests(GitFixture, unittest.TestCase):
    def run_step(self, base="", event="push", full="false", meson_available=True):
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
        kodev = self.repo / "kodev"
        kodev.write_text("#!/bin/sh\necho " + ("true" if meson_available else "false") + "\n")
        kodev.chmod(0o755)
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

    def test_selection_runs_on_host_to_receive_ci_inputs_and_outputs(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/fork_emulator.yml").read_text()
        step = workflow.split("      - name: Select affected front unit suites\n", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("        shell: bash\n", step)
        self.assertIn("./kodev docker kontainer exec", step)

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

    def test_integration_only_workflow_selects_none_without_fake_stats(self):
        self.write("spec/integration/scenarios/example.lua", "return {}")
        self.commit()
        code, manifest = self.run_step(self.base)
        self.assertEqual(code, 0)
        self.assertEqual(manifest["mode"], "none")
        self.assertEqual(manifest["tests"], [])
        self.assertFalse((self.repo / "coverage/unit.stats.out").exists())
        self.assertTrue((self.repo / "coverage/unit-selection.json").exists())

    def test_initial_push_empty_or_zero_before_runs_full_with_null_base(self):
        for before in ("", "0" * 40):
            with self.subTest(before=before):
                code, manifest = self.run_step(before)
                self.assertEqual(code, 0)
                self.assertEqual(manifest["mode"], "full")
                self.assertIsNone(manifest["base_sha"])
                self.assertEqual(manifest["base_unit_tests"], "full")

    def test_missing_meson_runs_full_but_keeps_the_real_base(self):
        self.write("frontend/leaf.lua", "return { changed = true }")
        self.commit()
        code, manifest = self.run_step(self.base, meson_available=False)
        self.assertEqual(code, 0)
        self.assertEqual(manifest["mode"], "full")
        self.assertEqual(manifest["base_sha"], self.base)
        self.assertEqual(manifest["base_unit_tests"], "full")

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


class CoveragePrefixTests(GitFixture, unittest.TestCase):
    def run_prefix(self, before, manifest_base=None):
        root = Path(__file__).resolve().parents[2]
        script = (root / ".ci/fork/coverage.sh").read_text().split("# luajit & luacov.", 1)[0]
        script += '\nprintf "MODE=%s ENFORCE=%s BASE=%s\\n" "$mode" "$enforce" "$base"\n'
        work = self.repo / "reporter-work"
        work.mkdir(exist_ok=True)
        artifacts = work / "artifacts"
        (artifacts / "unit-coverage").mkdir(parents=True, exist_ok=True)
        manifest = selector.select(self.repo)
        manifest["base_sha"] = manifest_base
        (artifacts / "unit-coverage/unit-selection.json").write_text(json.dumps(manifest))
        env = dict(os.environ, EVENT_NAME="push", COVERAGE_MODE="diff", PUSH_BEFORE=before,
                   PR_NUMBER="", PR_BASE="", RUNNER_TEMP=str(work),
                   GITHUB_OUTPUT=str(work / "output"), GITHUB_STEP_SUMMARY=str(work / "summary"))
        result = subprocess.run(["bash", "-eo", "pipefail", "-c", script, "coverage-prefix", str(artifacts)],
                                cwd=self.repo, env=env, capture_output=True, text=True)
        return result, work

    def test_initial_push_uses_empty_tree_and_checks_all_source(self):
        for before in ("", "0" * 40):
            with self.subTest(before=before):
                result, work = self.run_prefix(before)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("MODE=diff ENFORCE=diff", result.stdout)
                diff = (work / "change.diff").read_text()
                for path in ("frontend/leaf.lua", "frontend/mid.lua", "frontend/other.lua"):
                    self.assertIn("+++ b/" + path, diff)

    def test_invalid_before_or_unproven_null_base_is_rejected(self):
        for before in ("invalid-ref", self.base):
            with self.subTest(before=before):
                result, _ = self.run_prefix(before)
                self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
