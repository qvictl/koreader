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
        local records
        if out then
            ffi.cdef[[
                int font_probe_live(void);
                int font_probe_made(void);
                int font_probe_dropped(void);
                int font_probe_peak(void);
                int font_probe_explicit(void);
                int font_probe_internal(void);
                void font_probe_snapshot(const char *stage);
            ]]
            records = assert(io.open(out .. "/memory.jsonl", "w"))
        end
        local function snapshot(stage, elapsed)
            T:run(function()
                collectgarbage(); collectgarbage()
                if not records then return end
                local row = { stage = stage, elapsed_ms = elapsed,
                    faces_live = ffi.C.font_probe_live(), faces_made = ffi.C.font_probe_made(),
                    faces_dropped = ffi.C.font_probe_dropped(), faces_peak = ffi.C.font_probe_peak(),
                    faces_explicit = ffi.C.font_probe_explicit(),
                    faces_library_cleanup = ffi.C.font_probe_internal(), lua_kb = collectgarbage("count") }
                for line in io.lines("/proc/self/smaps_rollup") do
                    local key, value = line:match("^(%w+):%s+(%d+) kB")
                    if key then row[key] = tonumber(value) end
                end
                for line in io.lines("/proc/self/status") do
                    local value = line:match("^VmHWM:%s+(%d+) kB")
                    if value then row.peak_rss_kb = tonumber(value) end
                end
                ffi.C.font_probe_snapshot(stage)
                records:write(require("json").encode(row), "\n"); records:flush()
                T:log("FONT_MEMORY", stage, require("json").encode(row))
                if stage:match("^closed_") and os.getenv("FONT_BENCH_EXPECT_ZERO") == "1" then
                    T:eq(row.faces_live, 0, "all native faces are destroyed after closing the book")
                end
            end)
        end
        snapshot("filemanager")
        local book = os.getenv("FONT_BENCH_BOOK") or T:fixture("books/zh.epub")
        local expected_pixels, expected_pages
        for cycle = 1, 3 do
            local ui, open_ms = T:openBook(book)
            T:run(function()
                ui.rolling:onGotoPage(1)
            end)
            T:repaint()
            snapshot("open_" .. cycle, open_ms)
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
        if records then records:close() end
    end,
}
