#!/usr/bin/env python3
"""Exercise the actual release workflow's early ref guard without network or publishing."""
import os
from pathlib import Path
import re
import subprocess
import unittest

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/fork_release.yml"


def early_check(text):
    step = text.split("        id: check\n", 1)[1]
    block = re.search(r"        run: \|\n((?:          .*\n|\n)+)", step).group(1)
    script = "\n".join(line[10:] for line in block.splitlines())
    # Execute the workflow verbatim up to the existing tag/network handling.
    return script.split('if [[ "${GITHUB_REF_TYPE}" == tag ]]; then', 1)[0]


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
        self.assertEqual(check_ref(self.script, "push", "", "refs/tags/v2026.10.q1"), 0)
        self.assertEqual(check_ref(self.script, "workflow_dispatch", "true", "refs/tags/v2026.10.q1"), 0)


if __name__ == "__main__":
    unittest.main()
