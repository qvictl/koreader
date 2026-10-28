-- Local research only: private definitions never leave memory.
return {
    name = "Real dictionary UI profile",
    timeout = 240,
    settings = { disable_lookup_history = true, dict_progressive_lookup = false },
    run = function(T)
        local RD = require("apps/reader/modules/readerdictionary")
        local QL = require("ui/widget/dictquicklookup")
        local UI = require("ui/uimanager")
        local json = require("rapidjson")
        local md5 = require("ffi/sha2").md5
        local time = require("ui/time")
        local function now() return time.to_us(time.monotonic()) / 1000 end
        local current, records = nil, {}
        local minimum = tonumber(os.getenv("DICT_PROFILE_POLL_MS"))
        if minimum then
            local replaced = false
            for i = 1, 20 do
                local name = debug.getupvalue(RD.waitForSdcv, i)
                if name == "getSdcvPollInterval" then
                    debug.setupvalue(RD.waitForSdcv, i, function(start)
                        return math.min(math.max(time.to_s(time.since(start)) / 8, minimum / 1000), 0.25)
                    end)
                    replaced = true
                    break
                end
            end
            assert(replaced, "poll interval probe unavailable")
        end
        local function add(key, value)
            if current then current[key] = (current[key] or 0) + value end
        end
        local util = require("ffi/util")
        local heartbeat_running = true
        local previous = now()
        local function heartbeat()
            local tick = now()
            if current then current.max_heartbeat_gap_ms = math.max(current.max_heartbeat_gap_ms or 0, tick - previous) end
            previous = tick
            if heartbeat_running then UI:scheduleIn(0.005, heartbeat) end
        end
        UI:scheduleIn(0.005, heartbeat)
        local proc_class
        for i = 1, 20 do
            local name, value = debug.getupvalue(RD.runSdcv, i)
            if name == "SdcvProcess" then proc_class = value; break end
        end
        assert(proc_class, "native process instrumentation unavailable")
        local saved = {}
        local function hook(object, name, make)
            saved[#saved + 1] = { object, name, object[name] }
            object[name] = make(object[name])
        end
        hook(proc_class, "new", function(original)
            return function(self, ...)
                local start = now()
                local proc = original(self, ...)
                add("spawn_ms", now() - start)
                if current and proc then
                    proc._profile_started = start
                    proc._profile_row = current
                    current.processes = (current.processes or 0) + 1
                    current.native_pid = proc.pid
                end
                return proc
            end
        end)
        hook(proc_class, "poll", function(original)
            return function(self, ...)
                local start = now()
                local done = original(self, ...)
                add("poll_cpu_ms", now() - start)
                add("poll_calls", 1)
                if done and self._profile_started then
                    local row = self._profile_row
                    row.sdcv_elapsed_ms = (row.sdcv_elapsed_ms or 0) + now() - self._profile_started
                    self._profile_started = nil
                end
                return done
            end
        end)
        hook(proc_class, "stop", function(original)
            return function(self, kill)
                if self._profile_row and kill then self._profile_row.cancel_signal = true end
                return original(self, kill)
            end
        end)
        hook(util, "isSubProcessDone", function(original)
            return function(pid, ...)
                local done = original(pid, ...)
                if current and pid == current.native_pid and done then current.reaped = true end
                return done
            end
        end)
        hook(proc_class, "getOutput", function(original)
            return function(self, ...)
                local start = now()
                local output = original(self, ...)
                add("concat_ms", now() - start)
                add("output_bytes", #output)
                return output
            end
        end)
        hook(json, "decode", function(original)
            return function(...)
                local start = now()
                local result = original(...)
                add("decode_ms", now() - start)
                return result
            end
        end)
        for _, name in ipairs({ "init", "_instantiateScrollWidget", "paintTo", "updateResults" }) do
            hook(QL, name, function(original)
                return function(self, ...)
                    local start = now()
                    local result = original(self, ...)
                    add("widget_" .. name .. "_ms", now() - start)
                    if current and name == "paintTo" and not current.first_ms then
                        current.first_ms = now() - current.started
                    end
                    if current and name == "paintTo" and not self.results_pending then
                        current.final_paint_ms = now() - current.started
                    end
                    return result
                end
            end)
        end
        hook(RD, "showDict", function(original)
            return function(self, ...)
                local start = now()
                local result = original(self, ...)
                add("show_dict_ms", now() - start)
                return result
            end
        end)
        local function digest(results)
            local feed = md5()
            local bytes = 0
            for _, r in ipairs(results) do
                for _, text in ipairs({ r.dict or "", r.word or "", r.definition or "" }) do
                    feed(tostring(#text) .. ":" .. text)
                    bytes = bytes + #text
                end
            end
            return feed(), bytes
        end
        local ui = T:openBook(T:fixture("books/en.epub"))
        T:eq(#ui.dictionary.enabled_dict_names, 3, "three real dictionaries are enabled")
        local expected = {}
        local words = { "test", "run", "harbor", "light", "accomodation", "qwxzvbnmplk" }
        local rounds = tonumber(os.getenv("DICT_PROFILE_ROUNDS")) or 1
        local ok, err = xpcall(function()
            for round = 1, rounds do
                for _, progressive in ipairs({ false, true }) do
                    G_reader_settings:saveSetting("dict_progressive_lookup", progressive)
                    for _, word in ipairs(words) do
                        current = { word = word, round = round, progressive = progressive,
                            rss_before_kb = T:rssKb(), lua_before_kb = collectgarbage("count") }
                        current.started = now()
                        current.cpu_started = os.clock() * 1000
                        previous = current.started
                        local row = current
                        T:run(function() ui.dictionary:onLookupWord(word, true) end)
                        local w = T:waitUntil(function()
                            local window = ui.dictionary.dict_window
                            return window and row.final_paint_ms and not window.results_pending and window
                        end, 40, "complete private lookup")
                        row.complete_ms = row.final_paint_ms
                        row.ui_cpu_ms = os.clock() * 1000 - row.cpu_started
                        current = nil
                        row.digest, row.definition_bytes = digest(w.results)
                        row.screen_md5 = md5(require("ffi/blitbuffer").tostring(require("device").screen.bb))
                        row.results = #w.results
                        if expected[word] then T:eq(row.digest, expected[word], "identical result digest")
                        else expected[word] = row.digest end
                        current = nil
                        row.rss_shown_kb, row.lua_shown_kb = T:rssKb(), collectgarbage("count")
                        T:run(function() w:onClose() end)
                        T:waitUntil(function() return not UI:isWidgetShown(w) end, 5, "dictionary closes")
                        row.rss_closed_kb, row.lua_closed_kb = T:rssKb(), collectgarbage("count")
                        row.started, row.cpu_started, row.native_pid = nil, nil, nil
                        row.minimum_poll_ms = minimum or 10
                        records[#records + 1] = row
                    end
                end
            end
            for _, progressive in ipairs({ false, true }) do
                G_reader_settings:saveSetting("dict_progressive_lookup", progressive)
                current = { kind = "cancel", progressive = progressive, word = "qwxzvbnmplk",
                    started = now(), minimum_poll_ms = minimum or 10 }
                previous = current.started
                local row = current
                T:run(function()
                    ui.dictionary:onLookupWord(row.word, true)
                    UI:forceRePaint()
                    local trap = T:topWidget()
                    assert(trap and trap.dismiss_callback, "real lookup trap is active")
                    local screen = require("device").screen
                    local start = now()
                    UI:sendEvent(T:tapEvent(screen:getWidth() / 2, screen:getHeight() / 2))
                    row.cancel_ms = now() - start
                end)
                T:check(row.cancel_signal, "real lookup cancellation reaches native process")
                T:waitUntil(function() return row.reaped end, 5, "exact cancelled native pid reaped")
                row.reap_ms = now() - row.started
                row.started, row.native_pid = nil, nil
                current = nil
                records[#records + 1] = row
            end
        end, debug.traceback)
        current = nil
        heartbeat_running = false
        UI:unschedule(heartbeat)
        for i = #saved, 1, -1 do local entry = saved[i]; entry[1][entry[2]] = entry[3] end
        local file = assert(io.open(os.getenv("IT_RESULT") .. ".profile.json", "w"))
        assert(file:write(json.encode(records))); assert(file:close())
        T:closeBook()
        if not ok then error(err, 0) end
    end,
}
