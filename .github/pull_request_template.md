<!--
Thanks for your contribution! PRs written by people or by AI are equally welcome here:
we gate on tests (see CONTRIBUTING.md). Please fill in every section.
AI reviewers and the review gate: see REVIEW_POLICY.md.
-->

### What and why

<!-- What does this change, and why? Link the issue if any. -->

### Tests

<!-- Which tests did you add or change, and what do they check?
     - unit tests: spec/unit/…
     - emulator integration scenario(s) (required for any user-visible feature or fix):
       spec/integration/scenarios/NN_name.lua — what it checks
     `no-tests-needed` (maintainers only) is for documentation, comments or log wording changes. -->

Integration scenario(s): <!-- e.g. 05_dictionary_progressive -->

### Test evidence

<!-- How did you run them, and what was the result? e.g.
     - `make testfront`: N successes / 0 failures
     - `./tools/run_integration_tests.sh`: optional local evidence; the full suite is required at release
     - device testing (model, firmware), before/after numbers for performance or memory changes -->

### Checklist

- [ ] Tests added or updated for every code change (or the reason why not is explained above)
- [ ] Integration scenario changes are ready for the release candidate suite (optional local results noted above)
- [ ] An emulator integration scenario covers the user-visible change (named above)
- [ ] Coverage check green: selected UT changed-line coverage ≥ 80%. Releases run full UT/IT and enforce separate unit/combined ratchets (0.1 pp allowance), dated unit/module targets, and unit + integration changed-line coverage ≥ 90%
- [ ] Every AI review comment flagged as a potential issue / bug is fixed or answered with a justification before resolving it ([REVIEW_POLICY.md](../blob/main/REVIEW_POLICY.md))
