-- Coverage policy of the qvictl/koreader fork (see CONTRIBUTING.md and .ci/fork/coverage.lua).
-- Dated targets tighten automatically: edit only to change the policy.
return {
    gates = {
        -- Blocking on every PR to main.
        diff_unit_min = 80,         -- % of the changed executable Lua lines run by the unit tests
        diff_combined_min = 90,     -- % run by the unit + emulator integration tests
        ratchet_tolerance_pp = 0.1, -- overall coverage may not drop below main's by more than this
    },
    -- Changed files the diff gates look at.
    diff_include = { "^frontend/", "^plugins/", "^[^/]+%.lua$" },
    -- Files the fork changed that may be owned modules (see owned-modules.txt).
    owned_include = { "^frontend/", "^plugins/", "^[^/]+%.lua$" },
    overall = {
        paths = { "frontend", "plugins" },
        exclude = { "^frontend/luxl%.lua$", "^plugins/newsdownloader%.koplugin/lib/" },
        -- Day-one measurement (unit + integration), and targets relative to it (report only;
        -- the ratchet against main is what blocks).
        baseline = { date = "2026-10-27", percent = 37.67 }, -- main @ 2e86f5405
        targets = {
            { from = "2026-11-24", delta_pp = 5 },
            { from = "2026-12-22", delta_pp = 10 },
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
