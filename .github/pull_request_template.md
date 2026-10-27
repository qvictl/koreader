<!--
Thanks for your contribution! PRs written by people or by AI are equally welcome here:
we gate on tests (see CONTRIBUTING.md). Please fill in every section.
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
     - `./tools/run_integration_tests.sh`: all scenarios passed (paste the summary table)
     - device testing (model, firmware), before/after numbers for performance or memory changes -->

### Checklist

- [ ] Tests added or updated for every code change (or the reason why not is explained above)
- [ ] `./tools/run_integration_tests.sh` passes locally (or I rely on CI and checked its results)
- [ ] An emulator integration scenario covers the user-visible change (named above)
- [ ] Coverage check green: changed lines ≥ 80% by unit tests and ≥ 90% by unit + integration tests, no overall drop, owned modules on target
