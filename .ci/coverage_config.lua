-- Coverage policy of the qvictl/koreader fork (see CONTRIBUTING.md and .ci/fork/coverage.lua).
-- Dated targets tighten automatically: edit only to change the policy.
return {
    gates = {
        -- Unit gates block PRs; combined gates block release candidates.
        diff_unit_min = 80,         -- % of the changed executable Lua lines run by the unit tests
        diff_combined_min = 90,     -- % run by the unit + emulator integration tests
        ratchet_tolerance_pp = 0.1, -- the selected metric may not drop below its measured ancestor by more than this
    },
    -- Changed files the diff gates look at.
    diff_include = { "^frontend/", "^plugins/", "^[^/]+%.lua$" },
    -- Files the fork changed that may be owned modules (see owned-modules.txt).
    owned_include = { "^frontend/", "^plugins/", "^[^/]+%.lua$" },
    overall = {
        paths = { "frontend", "plugins" },
        exclude = { "^frontend/luxl%.lua$", "^plugins/newsdownloader%.koplugin/lib/" },
        -- Day-one measurement (unit + integration), and targets relative to it (report only;
        -- the ratchet against main at the PR's base is what blocks).
        baseline = { date = "2026-10-27", percent = 37.67 }, -- main @ 2e86f5405
        targets = {
            { from = "2026-11-24", delta_pp = 5 },
            { from = "2026-12-22", delta_pp = 10 },
        },
        -- The same paths, covered by the unit tests alone (spec/unit). Unlike the targets
        -- above, these are blocking (the "unit" gate) from their date. Plan: doc/coverage-plan.md.
        unit = {
            baseline = { date = "2026-10-27", percent = 31.47 }, -- main @ 76b8c107f (unit stats only)
            targets = {
                { from = "2026-11-24", delta_pp = 5 },  -- ≥ 36.47%
                { from = "2026-12-22", delta_pp = 10 }, -- ≥ 41.47%
            },
        },
    },
    owned = {
        list = ".ci/owned-modules.txt",
        targets = {
            { from = "2026-10-27", min = 80 },
            { from = "2026-11-24", min = 85 },
            { from = "2026-12-22", min = 90 },
        },
    },
    -- luacov stats path prefix -> repository path prefix.
    stats_path_map = {
        { "ffi/", "base/ffi/" },
    },
}
