-- sdcv (built from koreader-base with skip_res_dirs.patch) must not walk into the res/
-- directories of HTML dictionaries: it would stat every resource file on every lookup,
-- and pick up any .ifo found in there.
return {
    name = "sdcv skips res/ directories",
    timeout = 60,
    run = function(T)
        local function sdcv(args)
            local p = io.popen("./sdcv " .. args .. " 2>&1")
            local out = p:read("*a")
            p:close()
            return out
        end
        local listing = sdcv("-l -n --data-dir '" .. T:fixture("dict") .. "'")
        T:log("sdcv -l:", (listing:gsub("\n", " | ")))
        T:check(listing:find("IT Gamma", 1, true), "sdcv lists the HTML dictionary")
        T:check(not listing:find("IT Decoy In Res", 1, true), "sdcv does not pick up the .ifo inside res/")
        local out = sdcv("-n -j --data-dir '" .. T:fixture("dict") .. "' lantern")
        T:check(out:find("IT Alpha", 1, true), "sdcv finds 'lantern'")
        T:check(not out:find("decoy", 1, true), "no result from the dictionary inside res/")
        -- Time 20 lookups (each walks the dictionary directory, as KOReader runs sdcv once per lookup).
        local t0 = T:now()
        for _ = 1, 20 do
            sdcv("-n -j --data-dir '" .. T:fixture("dict") .. "' harbor")
        end
        T:budget("sdcv_lookup_ms", (T:now() - t0) / 20, 500, "ms")
    end,
}
