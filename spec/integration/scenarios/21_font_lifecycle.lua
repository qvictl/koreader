-- Native font ownership is checked by crengine's font_gc test; this scenario
-- guards rendering and the real ReaderUI close/reopen path around collection.
return {
    name = "Native font collection preserves rendering across book lifetimes",
    timeout = 300,
    settings = {
        low_memory_profile = true,
        cre_storage_size_factor = 4,
        cre_font = os.getenv("FONT_BENCH_FONT") or "Noto Sans CJK SC",
        cre_header_clock = 0,
        cre_header_battery = 0,
        footer = { disabled = true },
    },
    run = function(T)
        local ffi = require("ffi")
        local Blitbuffer = require("ffi/blitbuffer")
        local Device = require("device")
        local out = os.getenv("FONT_BENCH_OUT")
        local records, traces
        if out then
            ffi.cdef[[
                int font_probe_live(void);
                int font_probe_made(void);
                int font_probe_dropped(void);
                int font_probe_peak(void);
                int font_probe_explicit(void);
                int font_probe_internal(void);
                const char *font_probe_snapshot(const char *stage);
            ]]
            records, traces = {}, {}
        end
        local function snapshot(stage, elapsed)
            local sample = T:run(function()
                collectgarbage(); collectgarbage()
                if not records then return end
                local row = { stage = stage, elapsed_ms = elapsed,
                    faces_live = ffi.C.font_probe_live(), faces_made = ffi.C.font_probe_made(),
                    faces_dropped = ffi.C.font_probe_dropped(), faces_peak = ffi.C.font_probe_peak(),
                    faces_explicit = ffi.C.font_probe_explicit(),
                    faces_library_cleanup = ffi.C.font_probe_internal(), lua_kb = collectgarbage("count") }
                -- Procfs must sample this process at the measurement boundary.
                -- A fork would itself alter PSS; these reads are test-only kernel data.
                for line in io.lines("/proc/self/smaps_rollup") do
                    local key, value = line:match("^(%w+):%s+(%d+) kB")
                    if key then row[key] = tonumber(value) end
                end
                for line in io.lines("/proc/self/status") do
                    local value = line:match("^VmHWM:%s+(%d+) kB")
                    if value then row.peak_rss_kb = tonumber(value) end
                end
                traces[#traces + 1] = ffi.string(ffi.C.font_probe_snapshot(stage))
                records[#records + 1] = require("json").encode(row)
                return row
            end)
            if sample and stage:match("^closed_") and os.getenv("FONT_BENCH_EXPECT_ZERO") == "1" then
                T:eq(sample.faces_live, 0, "all native faces are destroyed after closing the book")
            end
        end
        local measured, measurement_error = pcall(function()
            snapshot("filemanager")
            local book = os.getenv("FONT_BENCH_BOOK") or T:fixture("books/zh.epub")
            local expected_pixels, expected_pages
            local made_before = out and ffi.C.font_probe_made() or nil
            for cycle = 1, 3 do
                local ui, open_ms = T:openBook(book)
                T:run(function()
                    ui.rolling:onGotoPage(1)
                end)
                T:repaint()
                snapshot("open_" .. cycle, open_ms)
                if cycle == 1 and made_before then
                    T:check(ffi.C.font_probe_made() > made_before and ffi.C.font_probe_live() > 0,
                        "opening the book creates observable live native faces")
                end
                local pages = ui.document:getPageCount()
                T:check(pages > 1, "the book contains multiple rendered pages")
                expected_pages = expected_pages or pages
                T:eq(pages, expected_pages, "page count survives collection and reopening")
                local t0 = T:now()
                for page = 2, math.min(21, math.max(2, pages - 1)) do
                    T:run(function() ui.rolling:onGotoPage(page) end)
                    T:repaint()
                end
                snapshot("paged_" .. cycle, T:now() - t0)
                local pixels = T:run(function()
                    if out then Device.screen:shot(out .. "/page21-" .. cycle .. ".png") end
                    return Blitbuffer.tostring(Device.screen.bb)
                end)
                expected_pixels = expected_pixels or pixels
                T:check(pixels == expected_pixels, "rendered pixels survive collection and reopening")
                t0 = T:now()
                T:closeBook()
                snapshot("closed_" .. cycle, T:now() - t0)
                if out then
                    T:wait(0.5)
                    snapshot("settled_" .. cycle)
                end
                T:check(T:reader() == nil, "the reader is released after closing")
                T:check(T:topWidget() == T:fileManager(), "closing returns to the browser")
            end
        end)
        local exported, export_error = pcall(function()
            if records then
                -- Export only after every measurement: disk I/O is outside the
                -- measured book lifecycle and cannot change a sampled PSS value.
                local function write_file(name, contents)
                    local file = assert(io.open(out .. "/" .. name, "w"))
                    local wrote, write_error = file:write(contents)
                    local closed, close_error = file:close()
                    assert(wrote, write_error)
                    assert(closed, close_error)
                end
                write_file("memory.jsonl", table.concat(records, "\n") .. "\n")
                write_file("faces.tsv", table.concat(traces))
            end
        end)
        if not measured then
            if not exported then T:log("snapshot export failed:", tostring(export_error)) end
            error(measurement_error, 0)
        end
        if not exported then error(export_error, 0) end
    end,
}
