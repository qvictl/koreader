#!/usr/bin/env python3
"""Exercise the actual release workflow's early ref guard without network or publishing."""
import os
from pathlib import Path
import re
import subprocess
import shutil
import tempfile
import unittest

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/fork_release.yml"


def full_check(text):
    step = text.split("        id: check\n", 1)[1]
    block = re.search(r"        run: \|\n((?:          .*\n|\n)+)", step).group(1)
    script = "\n".join(line[10:] for line in block.splitlines())
    return script


def early_check(text):
    # Execute the workflow verbatim up to the existing tag/network handling.
    return full_check(text).split('if [[ "${GITHUB_REF_TYPE}" == tag ]]; then', 1)[0]


def check_ref(script, event, publish, ref):
    env = dict(os.environ, GITHUB_EVENT_NAME=event, PUBLISH=publish, GITHUB_REF=ref)
    return subprocess.run(["bash", "-eo", "pipefail", "-c", script], env=env,
                          capture_output=True, text=True).returncode


class ReleaseRefTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = early_check(WORKFLOW.read_text())

    def test_dry_run_accepts_current_main_branch(self):
        self.assertEqual(check_ref(self.script, "workflow_dispatch", "false", "refs/heads/main"), 0)

    def test_dry_run_rejects_feature_branch(self):
        self.assertNotEqual(check_ref(self.script, "workflow_dispatch", "false", "refs/heads/feature"), 0)

    def test_dry_run_rejects_historical_tag(self):
        self.assertNotEqual(check_ref(self.script, "workflow_dispatch", "false", "refs/tags/v2026.10.q1"), 0)

    def test_dry_run_rejects_tag_named_main(self):
        self.assertNotEqual(check_ref(self.script, "workflow_dispatch", "false", "refs/tags/main"), 0)

    def test_regular_tag_release_keeps_its_existing_validation(self):
        real_git = shutil.which("git")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote, repo, binaries = root / "origin.git", root / "source", root / "bin"
            subprocess.run([real_git, "init", "--quiet", "--bare", str(remote)], check=True)
            subprocess.run([real_git, "init", "--quiet", "-b", "main", str(repo)], check=True)

            def git(*args):
                return subprocess.check_output([real_git, "-C", str(repo), *args], text=True).strip()

            def commit(message):
                git("-c", "user.name=unit", "-c", "user.email=unit@example.com", "-c",
                    "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", message)
                return git("rev-parse", "HEAD")

            ancestor = commit("ancestor")
            commit("main")
            git("remote", "add", "origin", str(remote))
            git("push", "--quiet", "origin", "HEAD:refs/heads/main")
            git("checkout", "--quiet", "--detach", ancestor)
            outside_main = commit("outside main")
            binaries.mkdir()
            mock_git = binaries / "git"
            mock_git.write_text("""#!/usr/bin/env bash
if [[ "$1" == ls-remote ]]; then
    [[ "$4" == https://github.com/koreader/koreader.git ]] || exit 99
    [[ "$TEST_UPSTREAM_TAG" != true ]] || exit 0
    exit 2
fi
exec "$REAL_GIT" "$@"
""")
            mock_git.chmod(0o755)
            script = full_check(WORKFLOW.read_text())

            def run_tag(sha, event="push", upstream="false"):
                output = root / "outputs"
                output.write_text("")
                env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                           REAL_GIT=real_git, TEST_UPSTREAM_TAG=upstream, GITHUB_SHA=sha,
                           GITHUB_EVENT_NAME=event, PUBLISH="true", GITHUB_REF_TYPE="tag",
                           GITHUB_REF_NAME="v2026.10.q1", GITHUB_REF="refs/tags/v2026.10.q1",
                           OVERLAY_BASES="v2026.07.1", FORCE="false", GITHUB_OUTPUT=str(output))
                result = subprocess.run(["bash", "-eo", "pipefail", "-c", script], cwd=repo,
                                        env=env, capture_output=True, text=True)
                return result, output.read_text().splitlines()

            for event in ("push", "workflow_dispatch"):
                result, outputs = run_tag(ancestor, event=event)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("channel=stable", outputs)
                self.assertIn("go=true", outputs)
            result, outputs = run_tag(ancestor, upstream="true")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("go=false", outputs)
            result, outputs = run_tag(outside_main)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("is not on main", result.stdout)
            self.assertNotIn("go=true", outputs)


if __name__ == "__main__":
    unittest.main()
