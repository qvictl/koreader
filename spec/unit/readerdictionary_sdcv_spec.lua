-- ReaderDictionary lookups with the real sdcv (and fake ones, to simulate a missing,
-- slow, hanging, crashing or garbage-outputting sdcv): classic and progressive lookups,
-- background lookups, interruption with a tap (Trapper), and the subprocess plumbing
-- (posix_spawn and fork fallbacks, pipe/read failures, process reaping).
describe("ReaderDictionary sdcv lookups", function()
    local DataStorage, DictQuickLookup, DocumentRegistry, ReaderUI, UIManager, Screen
    local StarDict, ffi, ffiUtil, time, util, logger
    local RD_MOD = "apps/reader/modules/readerdictionary"
    local readerui, rd, ReaderDictionary
    local tmp, dict_dir, sdcv_path

    -- Runs the UI loop tasks until cond() is true (or timeout seconds have passed).
    local function waitFor(cond, timeout)
        local deadline = time.now() + time.s(timeout or 10)
        while not cond() do
            if time.now() > deadline then
                return false
            end
            UIManager:_checkTasks()
            ffiUtil.usleep(2000)
        end
        return true
    end

    -- Runs the UI loop tasks for a while.
    local function runTasksFor(seconds)
        waitFor(function() return false end, seconds)
    end

    local function upvalueIndex(func, name)
        local i = 1
        while true do
            local n = debug.getupvalue(func, i)
            if n == nil then
                error("no upvalue " .. name)
            end
            if n == name then
                return i
            end
            i = i + 1
        end
    end

    local function getUpvalue(func, name)
        local _, v = debug.getupvalue(func, upvalueIndex(func, name))
        return v
    end

    -- Replaces a module local (an upvalue of func, shared by all the module's closures);
    -- returns a function restoring it.
    local function setUpvalue(func, name, value)
        local idx = upvalueIndex(func, name)
        local _, orig = debug.getupvalue(func, idx)
        debug.setupvalue(func, idx, value)
        return function() debug.setupvalue(func, idx, orig) end
    end

    local function writeScript(name, body)
        local path = tmp .. "/" .. name
        local f = assert(io.open(path, "w"))
        f:write("#!/bin/sh\n", body, "\n")
        f:close()
        os.execute("chmod +x '" .. path .. "'")
        return path
    end

    -- Makes rd use another sdcv executable.
    local function useSdcv(instance, path)
        instance.getSdcvArgs = function(this, ...)
            local args = ReaderDictionary.getSdcvArgs(this, ...)
            args[1] = path
            return args
        end
    end

    local function processExists(pid)
        return ffi.C.kill(pid, 0) == 0
    end

    local function readPid(path)
        local f = io.open(path)
        if not f then return end
        local pid = tonumber(f:read("*a"))
        f:close()
        return pid
    end

    local function dicts(results)
        local t = {}
        for i, r in ipairs(results) do
            t[i] = r.dict .. "|" .. r.word
        end
        return t
    end

    local function lookup(word, opts)
        opts = opts or {}
        rd.dict_window = nil
        local instance = opts.instance or rd
        instance.dict_window = nil
        instance:onLookupWord(word, opts.is_sane ~= false, nil, opts.highlight, nil, opts.dict_close_callback)
        if opts.no_wait then
            return
        end
        assert.is_true(waitFor(function() return instance.dict_window ~= nil end), "no dict window for " .. word)
        if not opts.no_wait_background then
            assert.is_true(waitFor(function() return next(instance.background_lookups) == nil end),
                "background lookup not done for " .. word)
        end
        return instance.dict_window
    end

    local function topWidget()
        local stack = UIManager._window_stack
        return stack[#stack] and stack[#stack].widget
    end

    local function closeAll()
        for i = #DictQuickLookup.window_list, 1, -1 do
            UIManager:close(DictQuickLookup.window_list[i])
        end
        for i = #UIManager._window_stack, 1, -1 do
            local w = UIManager._window_stack[i].widget
            if w ~= readerui then
                UIManager:close(w)
            end
        end
        -- Let any killed sdcv be collected
        runTasksFor(0.05)
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        DataStorage = require("datastorage")
        DictQuickLookup = require("ui/widget/dictquicklookup")
        DocumentRegistry = require("document/documentregistry")
        UIManager = require("ui/uimanager")
        Screen = require("device").screen
        StarDict = require("stardict_fixture")
        ffi = require("ffi")
        ffiUtil = require("ffi/util")
        time = require("ui/time")
        util = require("util")
        logger = require("logger")
        sdcv_path = ffiUtil.realpath("./sdcv")

        tmp = DataStorage:getDataDir() .. "/readerdictionary_sdcv"
        StarDict.purge(tmp)
        util.makePath(tmp)
        dict_dir = tmp .. "/dict"
        StarDict.write(dict_dir .. "/alpha", "alpha", "Alpha", {
            harbor = "alpha: a sheltered port",
            lantern = "alpha: a lamp",
            ["-suffix"] = "alpha: a suffix",
        }, { lang = "en-fr" })
        StarDict.write(dict_dir .. "/beta", "beta", "Beta", {
            harbor = "beta: another harbor",
            beacon = "beta: a signal fire (only in beta)",
        })
        local gamma_ifo = StarDict.write(dict_dir .. "/gamma", "gamma", "Gamma", {
            harbor = "<b>harbor</b><hr>gamma html",
        }, {
            sametypesequence = "h",
            css = "b { color: red; }",
            fix_lua = 'return function(html, dict_path) return (html:gsub("<hr>", "<hr/>")) .. "<!--" .. dict_path .. "-->" end',
            res = true,
        })
        -- Must not be found: in a res/ directory
        StarDict.write(dict_dir .. "/gamma/res/decoy", "decoy", "Decoy", { harbor = "decoy!" })
        StarDict.write(dict_dir .. "/delta", "delta", "Delta", {
            beacon = "<i>delta beacon</i>",
        }, {
            sametypesequence = "h",
            fix_lua = 'return function() error("broken fix") end',
        })
        StarDict.write(dict_dir .. "/epsilon", "epsilon", "Epsilon", {
            lantern = "<![CDATA[first<br>&b{bold} &amp; more]]>",
        }, {
            fix_lua = "this is not lua",
        })
        -- Must not be found: no bookname
        StarDict.write(dict_dir .. "/noname", "noname", nil, { harbor = "nameless" })
        StarDict.write(dict_dir .. "_ext/ext", "ext", "Ext", {
            harbor = "ext: harbor in dict_ext",
            lantern = "ext: lantern in dict_ext",
        })
        assert(gamma_ifo)

        G_defaults:saveSetting("STARDICT_DATA_DIR", dict_dir)
        ReaderUI = require("apps/reader/readerui")
        ReaderDictionary = require(RD_MOD)
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument("spec/front/unit/data/sample.txt"),
        }
        rd = readerui.dictionary
    end)

    teardown(function()
        closeAll()
        ReaderUI.instance = readerui
        readerui:closeDocument()
        readerui:onClose()
        G_defaults:delSetting("STARDICT_DATA_DIR")
        G_reader_settings:delSetting("dict_progressive_lookup")
        UIManager:quit()
        UIManager._exit_code = nil
        StarDict.purge(tmp)
    end)

    before_each(function()
        ReaderUI.instance = readerui
        UIManager:show(readerui)
        G_reader_settings:delSetting("dict_progressive_lookup")
        rd.disable_fuzzy_search = false
    end)

    after_each(function()
        closeAll()
        -- Per-instance state some tests change: reset it even when they fail.
        rd.doc_disabled_dicts = {}
        rd.disable_lookup_history = false
        rd.getSdcvArgs = nil
        rd.quick_dismiss_before_delay = time.s(3)
    end)

    describe("dictionaries discovery", function()
        it("should find dictionaries in dict and dict_ext, sorted by name, skipping res/ and nameless ones", function()
            assert.are.same({ "Alpha", "Beta", "Delta", "Epsilon", "Ext", "Gamma" }, rd.enabled_dict_names)
            local nb_available, nb_enabled, nb_disabled = rd:getNumberOfDictionaries()
            assert.are.equal(6, nb_available)
            assert.are.equal(6, nb_enabled)
            assert.are.equal(0, nb_disabled)
            assert.are.same({ dict_dir, dict_dir .. "_ext" }, rd:getDictDirs())
        end)

        it("should follow the user's order, with unordered dictionaries last", function()
            local ifos = getUpvalue(ReaderDictionary.sortAvailableIfos, "available_ifos")
            local file_by_name = {}
            for _, ifo in ipairs(ifos) do
                file_by_name[ifo.name] = ifo.file
            end
            local orig_order = rd.dicts_order
            finally(function()
                rd.dicts_order = orig_order
                rd:sortAvailableIfos()
                rd:updateSdcvDictNamesOptions()
            end)
            rd.dicts_order = { [file_by_name.Gamma] = 1, [file_by_name.Ext] = 2 }
            rd:sortAvailableIfos()
            rd:updateSdcvDictNamesOptions()
            assert.are.same({ "Gamma", "Ext", "Alpha", "Beta", "Delta", "Epsilon" }, rd.enabled_dict_names)
            rd.dicts_order = orig_order
            rd:sortAvailableIfos()
            rd:updateSdcvDictNamesOptions()
            assert.are.same({ "Alpha", "Beta", "Delta", "Epsilon", "Ext", "Gamma" }, rd.enabled_dict_names)
        end)

        it("should skip globally disabled dictionaries, but keep preferred ones first", function()
            local ifos = getUpvalue(ReaderDictionary.sortAvailableIfos, "available_ifos")
            local beta_file
            for _, ifo in ipairs(ifos) do
                if ifo.name == "Beta" then beta_file = ifo.file end
            end
            -- (ReaderDictionary:init() guarantees the setting exists: restore its previous value)
            local prev_disabled = G_reader_settings:readSetting("dicts_disabled")
            finally(function()
                G_reader_settings:saveSetting("dicts_disabled", prev_disabled)
                rd.preferred_dictionaries = {}
                rd:updateSdcvDictNamesOptions()
            end)
            G_reader_settings:saveSetting("dicts_disabled", { [beta_file] = true })
            rd.preferred_dictionaries = { "Gamma" }
            rd:updateSdcvDictNamesOptions()
            assert.are.same({ "Gamma", "Alpha", "Delta", "Epsilon", "Ext" }, rd.enabled_dict_names)
            -- A preferred dictionary is used even if globally disabled
            rd.preferred_dictionaries = { "Beta" }
            rd:updateSdcvDictNamesOptions()
            assert.are.same({ "Beta", "Alpha", "Delta", "Epsilon", "Ext", "Gamma" }, rd.enabled_dict_names)
        end)
    end)

    describe("sdcv arguments", function()
        it("should build exact or fuzzy, dictionary restricted, option-safe arguments", function()
            local args = rd:getSdcvArgs("/some/dir", { "-word", "x" }, { "Alpha", "Beta" }, false)
            assert.are.same({ "./sdcv", "--utf8-input", "--utf8-output", "--json-output", "--non-interactive",
                "--data-dir", "/some/dir", "--exact-search", "-u", "Alpha", "-u", "Beta", "--", "-word", "x" }, args)
            args = rd:getSdcvArgs("/some/dir", { "word" }, nil, true)
            assert.are.same({ "./sdcv", "--utf8-input", "--utf8-output", "--json-output", "--non-interactive",
                "--data-dir", "/some/dir", "--", "word" }, args)
        end)

        it("should add the lowercased word for exact searches only", function()
            local words, fuzzy = rd:getSdcvWords("Harbor", false)
            assert.are.same({ "Harbor", "harbor" }, words)
            assert.is_false(fuzzy)
            words, fuzzy = rd:getSdcvWords("Harbor", true)
            assert.are.same({ "Harbor" }, words)
            assert.is_true(fuzzy)
        end)

        it("should add language plugins candidates, without duplicates", function()
            local ls = readerui.languagesupport
            stub(ls, "hasActiveLanguagePlugins", function() return true end)
            stub(ls, "extraDictionaryFormCandidates", function() return { "harbors", "harbor", "harbour" } end)
            local words = rd:getSdcvWords("harbors", true)
            assert.are.same({ "harbors", "harbor", "harbour" }, words)
            ls.hasActiveLanguagePlugins:revert()
            ls.extraDictionaryFormCandidates:revert()
        end)

        it("should never fuzzy search all-CJK words", function()
            local words, fuzzy = rd:getSdcvWords("君子", true)
            assert.are.same({ "君子" }, words)
            assert.is_false(fuzzy)
            -- (one non-CJK candidate is enough to allow it)
            local _, fuzzy2 = rd:getSdcvWords("Kanji", true)
            assert.is_true(fuzzy2)
        end)
    end)

    describe("classic lookup", function()
        before_each(function()
            G_reader_settings:makeFalse("dict_progressive_lookup")
        end)

        it("should show the results of all dictionaries, dict_ext ones last, with markup handled", function()
            local w = lookup("harbor")
            assert.are.same({ "Alpha|harbor", "Beta|harbor", "Gamma|harbor", "Ext|harbor" }, dicts(w.results))
            assert.is_false(w.results_pending)
            -- Plain text: leading newline stripped
            assert.are.equal("alpha: a sheltered port", w.results[1].definition)
            assert.are.same({ lang_in = "en", lang_out = "fr" }, w.results[1].ifo_lang)
            -- HTML dictionary: its css, its fix function (given the dict path), and its res/ directory
            local gamma = w.results[3]
            assert.is_true(gamma.is_html)
            assert.are.equal("b { color: red; }", gamma.css)
            assert.are.equal("\n<b>harbor</b><hr/>gamma html<!--" .. dict_dir .. "/gamma/-->", gamma.definition)
            assert.are.equal(dict_dir .. "/gamma/res", gamma.dictionary_resource_directory)
            assert.are.equal("1 / 4", w.displaynb)
        end)

        it("should strip CDATA, format escapes, entities and tags from plain text definitions", function()
            local w = lookup("lantern")
            assert.are.same({ "Alpha|lantern", "Epsilon|lantern", "Ext|lantern" }, dicts(w.results))
            assert.are.equal("first\nbold & more", w.results[2].definition)
        end)

        it("should keep the definition when a dictionary's fix function fails", function()
            local warn = spy.on(logger, "warn")
            local w = lookup("beacon")
            assert.are.same({ "Beta|beacon", "Delta|beacon" }, dicts(w.results))
            assert.are.equal("\n<i>delta beacon</i>", w.results[2].definition)
            assert.spy(warn).was_called_with("Dict's user provided function failed:", match.is_string())
            logger.warn:revert()
        end)

        it("should merge the results of dict and dict_ext per word", function()
            -- Exact search: "Lantern" and "lantern" are both looked up
            rd.disable_fuzzy_search = true
            local w = lookup("Lantern")
            assert.are.same({ "Alpha|lantern", "Epsilon|lantern", "Ext|lantern" }, dicts(w.results))
        end)

        it("should look up words starting with a dash as words, not sdcv options", function()
            local w = lookup("-suffix")
            assert.are.same({ "Alpha|-suffix" }, dicts(w.results))
        end)

        it("should fuzzy search when enabled", function()
            local w = lookup("harbr")
            assert.is_true(#w.results >= 1)
            assert.are.equal("harbor", w.results[1].word)
        end)

        it("should show 'No results.' when nothing is found with fuzzy search and no presets", function()
            local w = lookup("qwxzvbnmplk")
            assert.are.equal(1, #w.results)
            assert.is_true(w.results[1].no_result)
            assert.are.equal("No results.", w.results[1].definition)
        end)

        it("should offer a fuzzy search when nothing is found with an exact search", function()
            rd.disable_fuzzy_search = true
            lookup("harbr", { no_wait = true })
            assert.is_true(waitFor(function()
                local w = topWidget()
                return w and w.title == "No results found"
            end))
            local dialog = topWidget()
            assert.are.equal("harbr", dialog:getInputText())
            assert.is_nil(rd.dict_window)
            -- "Fuzzy search" button: looks the (possibly edited) word up again, fuzzily
            local button = dialog.button_table:getButtonById("close")
            assert.truthy(button)
            local fuzzy_button
            for _, row in ipairs(dialog.buttons) do
                for _, b in ipairs(row) do
                    if b.text == "Fuzzy search" then fuzzy_button = b end
                end
            end
            fuzzy_button.callback()
            assert.is_true(waitFor(function() return rd.dict_window ~= nil end))
            assert.are.equal("harbor", rd.dict_window.results[1].word)
        end)

        it("should clear the highlight when the 'No results found' dialog is cancelled", function()
            rd.disable_fuzzy_search = true
            local highlight = { clear = spy.new(function() end) }
            local closed = spy.new(function() end)
            lookup("qwxzvbnmplk", { no_wait = true, highlight = highlight, dict_close_callback = closed })
            assert.is_true(waitFor(function()
                local w = topWidget()
                return w and w.title == "No results found"
            end))
            local dialog = topWidget()
            dialog.button_table:getButtonById("close").callback()
            assert.is_false(UIManager:isWidgetShown(dialog))
            -- (after a delay)
            assert.spy(closed).was_not_called()
            UIManager:shiftScheduledTasksBy(-1e9)
            UIManager:_checkTasks()
            assert.spy(closed).was_called(1)
            assert.spy(highlight.clear).was_called()
        end)

        it("should not look up when all dictionaries are disabled for this book", function()
            rd.doc_disabled_dicts = {}
            for _, name in ipairs(rd.enabled_dict_names) do
                rd.doc_disabled_dicts[name] = true
            end
            local run = spy.on(rd, "runSdcv")
            finally(function() rd.runSdcv:revert() end)
            local w = lookup("harbor")
            assert.spy(run).was_not_called()
            assert.is_true(w.results[1].no_result)
            assert.matches("no enabled dictionaries", w.results[1].definition)
            rd.doc_disabled_dicts = {}
        end)

        it("should only look up the dictionaries not disabled for this book", function()
            rd.doc_disabled_dicts = { Beta = true, Gamma = true }
            local w = lookup("harbor")
            assert.are.same({ "Alpha|harbor", "Ext|harbor" }, dicts(w.results))
            rd.doc_disabled_dicts = {}
        end)

        it("should say no dictionaries are installed when there are none", function()
            local empty_dir = tmp .. "/empty/dict"
            util.makePath(empty_dir)
            local data_dir = rd.data_dir
            rd.data_dir = empty_dir
            local run = spy.on(rd, "runSdcv")
            local results = rd:startSdcv("harbor", nil, true)
            rd.runSdcv:revert()
            rd.data_dir = data_dir
            assert.spy(run).was_not_called()
            assert.are.equal(1, #results)
            assert.matches("No dictionaries installed", results[1].definition)
        end)

        it("should record lookups in the history, unless disabled", function()
            local menu_items = {}
            rd:addToMainMenu(menu_items)
            local history_item = menu_items.dictionary_lookup_history
            lookup("lantern")
            runTasksFor(0.05)
            assert.is_true(history_item.enabled_func())
            history_item.callback()
            local kv_page = topWidget()
            local kv_pairs = kv_page.kv_pairs
            assert.are.equal("lantern", kv_pairs[2][2])
            assert.matches("sample", kv_pairs[1][1])
            UIManager:close(kv_page)
            -- Tapping an entry looks it up again
            local on_lookup = stub(rd, "onLookupWord")
            kv_pairs[2].callback()
            rd.onLookupWord:revert()
            assert.stub(on_lookup).was_called_with(match.is_ref(rd), "lantern", true)

            rd.disable_lookup_history = true
            local nb = #kv_pairs
            lookup("beacon")
            runTasksFor(0.05)
            history_item.callback()
            assert.are.equal(nb, #topWidget().kv_pairs)
            rd.disable_lookup_history = false
        end)
    end)

    describe("progressive lookup", function()
        local function classic(word)
            G_reader_settings:makeFalse("dict_progressive_lookup")
            local results = dicts(lookup(word).results)
            closeAll()
            G_reader_settings:makeTrue("dict_progressive_lookup")
            return results
        end

        it("should split the lookup by first dictionary, then by dictionary directory", function()
            local queries, names_by_dir = rd:getProgressiveQueries(rd.enabled_dict_names)
            assert.are.equal(3, #queries)
            assert.are.same({ "Alpha" }, queries[1].dict_names)
            assert.are.equal(dict_dir, queries[1].dict_dir)
            assert.are.same({ "Beta", "Delta", "Epsilon", "Gamma" }, queries[2].dict_names)
            assert.are.same({ "Ext" }, queries[3].dict_names)
            assert.are.equal(dict_dir .. "_ext", queries[3].dict_dir)
            assert.are.same({ { "Alpha", "Beta", "Delta", "Epsilon", "Gamma" }, { "Ext" } }, names_by_dir)
        end)

        it("should not split lookups that can't or needn't be", function()
            assert.is_nil(rd:getProgressiveQueries(nil))
            assert.is_nil(rd:getProgressiveQueries({ "Alpha" }))
            -- unknown dictionaries are ignored, as sdcv would
            assert.is_nil(rd:getProgressiveQueries({ "Nope", "Unknown" }))
            assert.is_nil(rd:getProgressiveQueries({ "Alpha", "Unknown" }))
        end)

        it("should show the first dictionary's results first, then add the others in the background", function()
            local expected = classic("harbor")
            local updates = {}
            local orig_update = DictQuickLookup.updateResults
            finally(function() DictQuickLookup.updateResults = orig_update end)
            DictQuickLookup.updateResults = function(this, results, pending)
                table.insert(updates, { n = #results, pending = pending, shown = this.dict_index })
                return orig_update(this, results, pending)
            end
            local w = lookup("harbor", { no_wait_background = true })
            assert.are.same({ "Alpha|harbor" }, dicts(w.results))
            assert.is_true(w.results_pending)
            assert.are.equal("1 / 1\u{2026}", w.displaynb)
            assert.is_true(waitFor(function() return next(rd.background_lookups) == nil end))
            DictQuickLookup.updateResults = orig_update
            assert.are.same(expected, dicts(w.results))
            assert.is_false(w.results_pending)
            assert.are.same({ n = 3, pending = true, shown = 1 }, updates[1])
            assert.are.same({ n = 4, pending = false, shown = 1 }, updates[#updates])
            assert.are.equal("1 / 4", w.displaynb_text.text)
            -- the results are processed as in a classic lookup
            assert.are.equal(dict_dir .. "/gamma/res", w.results[3].dictionary_resource_directory)
        end)

        it("should look up the other dictionaries right away when the first one has no result", function()
            local expected = classic("beacon")
            local w = lookup("beacon")
            assert.are.same(expected, dicts(w.results))
            assert.are.same({ "Beta|beacon", "Delta|beacon" }, expected)
        end)

        it("should fuzzy search only after all exact searches failed, as sdcv does", function()
            local expected = classic("harbr")
            local w = lookup("harbr")
            assert.are.same(expected, dicts(w.results))
            assert.are.equal("harbor", w.results[1].word)
        end)

        it("should give the same 'No results' as a classic lookup", function()
            local w = lookup("qwxzvbnmplk")
            assert.is_true(w.results[1].no_result)
            assert.are.equal("No results.", w.results[1].definition)
        end)

        it("should fall back to a classic lookup when there is a single dictionary", function()
            local classic_spy = spy.on(rd, "startSdcv")
            local results = rd:startProgressiveSdcv("harbor", { "Alpha" }, false)
            assert.spy(classic_spy).was_called(1)
            rd.startSdcv:revert()
            assert.are.same({ "Alpha|harbor" }, dicts(results))
        end)

        it("should stop the background lookup (and kill its sdcv) when the window is closed", function()
            local pid_file = tmp .. "/bg_close.pid"
            os.remove(pid_file)
            local w = lookup("harbor", { no_wait_background = true })
            -- Next queries go to an sdcv that never ends
            useSdcv(rd, writeScript("sdcv_hang_bg", "echo $$ > '" .. pid_file .. "'; exec sleep 30"))
            assert.is_true(waitFor(function() return readPid(pid_file) ~= nil end))
            local pid = readPid(pid_file)
            local lookup_state = next(rd.background_lookups)
            assert.truthy(lookup_state.proc)
            local proc = lookup_state.proc
            assert.truthy(w.close_widget_callback)
            w:onClose()
            assert.is_nil(next(rd.background_lookups))
            assert.is_nil(w.close_widget_callback)
            assert.is_nil(lookup_state.proc)
            -- killed, and collected (no zombie left)
            assert.is_true(waitFor(function() return not processExists(pid) end, 3))
            -- A stopped sdcv process has nothing more to give
            assert.is_true(proc:poll())
            proc:wait()
            proc:stop(true)
            assert.are.equal("", proc:getOutput())
            -- Cancelling again is harmless
            rd:cancelBackgroundLookup(lookup_state)
        end)

        it("should keep polling a slow background sdcv", function()
            local w = lookup("harbor", { no_wait_background = true })
            useSdcv(rd, writeScript("sdcv_slow", "sleep 0.1; exec '" .. sdcv_path .. "' \"$@\""))
            local lookup_state = next(rd.background_lookups)
            local sched = spy.on(UIManager, "scheduleIn")
            assert.is_true(waitFor(function() return next(rd.background_lookups) == nil end))
            UIManager.scheduleIn:revert()
            local polls = 0
            for _, call in ipairs(sched.calls) do
                if call.vals[3] == lookup_state.poll_func then
                    polls = polls + 1
                end
            end
            -- 2 queries (other dictionaries in dict, then dict_ext), each taking a while
            assert.is_true(polls > 2)
            assert.is_false(w.results_pending)
            assert.are.equal(4, #w.results)
        end)

        it("should stop the background lookup if its window went away unnoticed", function()
            local w = lookup("harbor", { no_wait_background = true })
            assert.truthy(next(rd.background_lookups))
            -- (close_widget_callback should prevent that, but let's make sure we don't spin forever)
            w.close_widget_callback = nil
            UIManager:close(w)
            assert.is_true(waitFor(function() return next(rd.background_lookups) == nil end, 3))
        end)

        it("should show what it has when sdcv can't be started for the background lookup", function()
            local w = lookup("harbor", { no_wait_background = true })
            useSdcv(rd, tmp .. "/no/such/sdcv")
            assert.is_true(waitFor(function() return next(rd.background_lookups) == nil end))
            assert.are.same({ "Alpha|harbor" }, dicts(w.results))
            assert.is_false(w.results_pending)
            assert.are.equal("1 / 1", w.displaynb_text.text)
        end)

        it("should give up the progressive lookup when the first sdcv can't be started", function()
            useSdcv(rd, tmp .. "/no/such/sdcv")
            local results, background = rd:startProgressiveSdcv("harbor", rd.enabled_dict_names, true)
            assert.is_nil(background)
            assert.is_true(results.lookup_cancelled)
            assert.is_true(results[1].no_result)
        end)
    end)

    describe("sdcv failures", function()
        before_each(function()
            G_reader_settings:makeFalse("dict_progressive_lookup")
        end)

        it("should end the lookup, clearing the highlight, when sdcv can't be started", function()
            local warn = spy.on(logger, "warn")
            useSdcv(rd, tmp .. "/no/such/sdcv")
            local highlight = { clear = spy.new(function() end) }
            local closed = spy.new(function() end)
            lookup("harbor", { no_wait = true, highlight = highlight, dict_close_callback = closed })
            assert.is_true(waitFor(function() return #closed.calls > 0 end, 3))
            assert.spy(highlight.clear).was_called()
            assert.is_nil(rd.dict_window)
            assert.spy(warn).was_called_with("ReaderDictionary: could not start sdcv:", match.is_string())
            logger.warn:revert()
            assert.is_false(rd:runSdcv(rd:getSdcvArgs(dict_dir, { "harbor" }, nil, false), false))
        end)

        it("should skip undecodable output lines, keeping words and results aligned", function()
            useSdcv(rd, writeScript("sdcv_garbage", "echo 'not json'; echo '[{\"dict\":\"Alpha\",\"word\":\"x\",\"definition\":\"y\"}]'"))
            local warn = spy.on(logger, "warn")
            local cancelled, results = rd:rawSdcv({ "a", "b", "c" }, nil, false, false)
            assert.is_false(cancelled)
            -- 2 lines (1 garbage) per dictionary directory, merged per word
            assert.are.equal(2, #results)
            assert.are.same({}, results[1])
            assert.are.equal(2, #results[2])
            assert.spy(warn).was_called_with("JSON data cannot be decoded", match._)
            assert.spy(warn).was_called_with("sdcv returned a different number of results than the number of words")
            logger.warn:revert()
        end)

        it("should show 'No results.' when sdcv crashes without output", function()
            useSdcv(rd, writeScript("sdcv_crash", "kill -SEGV $$"))
            local w = lookup("harbor")
            assert.is_true(w.results[1].no_result)
            assert.are.equal("No results.", w.results[1].definition)
        end)

        it("should show 'No results.' when sdcv crashes in a progressive lookup too", function()
            G_reader_settings:makeTrue("dict_progressive_lookup")
            local nb_runs = 0
            local run = rd.runSdcv
            finally(function() rd.runSdcv = nil end)
            rd.runSdcv = function(...)
                nb_runs = nb_runs + 1
                return run(...)
            end
            useSdcv(rd, writeScript("sdcv_crash2", "kill -SEGV $$"))
            local w = lookup("harbor")
            -- all the (exact) queries were tried
            assert.are.equal(3, nb_runs)
            assert.is_true(w.results[1].no_result)
            assert.are.equal("No results.", w.results[1].definition)
        end)

        it("should kill a hanging sdcv when the lookup is interrupted by a tap", function()
            local pid_file = tmp .. "/hang.pid"
            os.remove(pid_file)
            useSdcv(rd, writeScript("sdcv_hang", "echo $$ > '" .. pid_file .. "'; exec sleep 30"))
            local highlight = { clear = spy.new(function() end) }
            local closed = spy.new(function() end)
            lookup("harbor", { no_wait = true, highlight = highlight, dict_close_callback = closed })
            assert.is_true(waitFor(function() return readPid(pid_file) ~= nil end))
            local pid = readPid(pid_file)
            -- The "Searching..." InfoMessage catches the tap (it closes itself on tap)
            local msg = rd.lookup_progress_msg
            assert.truthy(msg)
            local waiting_dismiss_callback = msg.dismiss_callback
            UIManager:close(msg)
            -- Interrupted quickly: nothing shown, highlight cleared
            assert.is_true(waitFor(function() return #closed.calls > 0 end, 3))
            assert.is_nil(rd.dict_window)
            assert.spy(highlight.clear).was_called()
            -- the InfoMessage got its own dismiss_callback back
            assert.are_not.equal(waiting_dismiss_callback, msg.dismiss_callback)
            assert.is_true(waitFor(function() return not processExists(pid) end, 3))
        end)

        it("should say the lookup was interrupted when it was after a while", function()
            local pid_file = tmp .. "/hang2.pid"
            os.remove(pid_file)
            useSdcv(rd, writeScript("sdcv_hang2", "echo $$ > '" .. pid_file .. "'; exec sleep 30"))
            rd.quick_dismiss_before_delay = 0 -- (as if the lookup had been going on for a while)
            local closed = spy.new(function() end)
            lookup("harbor", { no_wait = true, dict_close_callback = closed })
            assert.is_true(waitFor(function() return readPid(pid_file) ~= nil end))
            local pid = readPid(pid_file)
            UIManager:close(rd.lookup_progress_msg)
            assert.is_true(waitFor(function() return rd.dict_window ~= nil end, 3))
            local w = rd.dict_window
            assert.is_true(w.results.lookup_cancelled)
            assert.are.equal("Dictionary lookup interrupted.", w.results[1].definition)
            assert.spy(closed).was_not_called()
            assert.is_true(waitFor(function() return not processExists(pid) end, 3))
        end)

        it("should interrupt a progressive lookup too", function()
            G_reader_settings:makeTrue("dict_progressive_lookup")
            local pid_file = tmp .. "/hang3.pid"
            os.remove(pid_file)
            useSdcv(rd, writeScript("sdcv_hang3", "echo $$ > '" .. pid_file .. "'; exec sleep 30"))
            rd.quick_dismiss_before_delay = 0
            lookup("harbor", { no_wait = true })
            assert.is_true(waitFor(function() return readPid(pid_file) ~= nil end))
            UIManager:close(rd.lookup_progress_msg)
            assert.is_true(waitFor(function() return rd.dict_window ~= nil end, 3))
            assert.are.equal("Dictionary lookup interrupted.", rd.dict_window.results[1].definition)
            assert.is_nil(next(rd.background_lookups))
            assert.is_true(waitFor(function() return not processExists(readPid(pid_file)) end, 3))
        end)

        it("should catch a tap with its own TrapWidget when not given any (i.e. language plugins lookups)", function()
            local TrapWidget = require("ui/widget/trapwidget")
            local Trapper = require("ui/trapper")
            local pid_file = tmp .. "/hang4.pid"
            os.remove(pid_file)
            useSdcv(rd, writeScript("sdcv_hang4", "echo $$ > '" .. pid_file .. "'; exec sleep 30"))
            local done, cancelled, results
            Trapper:wrap(function()
                cancelled, results = rd:rawSdcv({ "harbor" }, nil, false)
                done = true
            end)
            assert.is_true(waitFor(function() return readPid(pid_file) ~= nil end))
            local trap = topWidget()
            assert.is_true(getmetatable(trap).__index == TrapWidget or trap.dismiss_callback ~= nil)
            assert.is_true(trap.resend_event) -- (the tap is given back to the UI)
            assert.is_true(trap.invisible)
            trap:onTapDismiss()
            assert.is_true(waitFor(function() return done end, 3))
            assert.is_true(cancelled)
            assert.are.same({}, results)
            assert.is_false(UIManager:isWidgetShown(trap))
            assert.is_true(waitFor(function() return not processExists(readPid(pid_file)) end, 3))

            -- and closes it when sdcv is done
            rd.getSdcvArgs = nil
            done = false
            local nb_widgets = #UIManager._window_stack
            Trapper:wrap(function()
                cancelled, results = rd:rawSdcv({ "beacon" }, { "Beta" }, false)
                done = true
            end)
            assert.are.equal(nb_widgets + 1, #UIManager._window_stack)
            assert.is_true(waitFor(function() return done end, 3))
            assert.is_false(cancelled)
            assert.are.equal("Beta", results[1][1].dict)
            assert.are.equal(nb_widgets, #UIManager._window_stack)
        end)

        it("should keep the input from dismissing results that came after a long lookup", function()
            local Input = require("device").input
            local inhibit = stub(Input, "inhibitInputUntil")
            rd.quick_dismiss_before_delay = 0
            lookup("harbor")
            assert.stub(inhibit).was_called_with(Input, true)
            Input.inhibitInputUntil:revert()
        end)

        it("should yield but check a ready short lookup within five milliseconds", function()
            local scheduled
            local schedule = stub(UIManager, "scheduleIn", function(_, delay, callback)
                scheduled = { delay = delay, callback = callback }
            end)
            finally(function() schedule:revert() end)
            local completed, output
            local process = {
                poll = function() return true end,
                getOutput = function() return "ready" end,
            }
            local worker = coroutine.create(function()
                completed, output = rd:waitForSdcv(process, { dismiss_callback = function() end })
            end)
            assert.is_true(coroutine.resume(worker))
            assert.are.equal("suspended", coroutine.status(worker))
            assert.is_nil(completed)
            assert.is_true(scheduled.delay > 0 and scheduled.delay <= 0.005)
            scheduled.callback()
            assert.are.equal("dead", coroutine.status(worker))
            assert.is_true(completed)
            assert.are.equal("ready", output)
        end)

        it("should back off long lookups instead of retaining the initial polling rate", function()
            local clock = time.s(10)
            local now = stub(time, "now", function() return clock end)
            local scheduled = {}
            local schedule = stub(UIManager, "scheduleIn", function(_, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end)
            finally(function() schedule:revert(); now:revert() end)
            local ready, completed = false, nil
            local process = {
                poll = function() return ready end,
                getOutput = function() return "ready" end,
            }
            local worker = coroutine.create(function()
                completed = rd:waitForSdcv(process, { dismiss_callback = function() end })
            end)
            assert.is_true(coroutine.resume(worker))
            clock = clock + time.ms(500)
            scheduled[1].callback()
            assert.is_nil(completed)
            assert.is_true(scheduled[2].delay >= 0.05 and scheduled[2].delay <= 0.25)
            clock = clock + time.s(10)
            scheduled[2].callback()
            assert.is_true(scheduled[3].delay >= 0.2 and scheduled[3].delay <= 0.25)
            ready = true
            scheduled[3].callback()
            assert.is_true(completed)
            assert.are.equal("dead", coroutine.status(worker))
        end)

        it("should block until sdcv is done when not run in a coroutine", function()
            local completed, output = rd:runSdcv(rd:getSdcvArgs(dict_dir, { "harbor" }, { "Beta" }, false))
            assert.is_true(completed)
            assert.matches("beta: another harbor", output)
        end)
    end)

    describe("subprocess plumbing", function()
        local SdcvProcess
        setup(function()
            SdcvProcess = getUpvalue(ReaderDictionary.runSdcv, "SdcvProcess")
        end)

        it("should collect the output of a process writing more than one read buffer", function()
            local proc = SdcvProcess:new({ "/bin/sh", "-c", "head -c 100000 /dev/zero | tr '\\0' x" })
            assert.truthy(proc)
            proc:wait()
            assert.are.equal(100000, #proc:getOutput())
            assert.is_true(proc:poll())
        end)

        it("should collect a process stopped while still running, once done (no zombie)", function()
            local proc = SdcvProcess:new({ "/bin/sh", "-c", "sleep 0.05" })
            local pid = proc.pid
            proc:stop() -- (not killed)
            assert.is_nil(proc.fd)
            assert.is_nil(proc.pid)
            assert.is_true(processExists(pid))
            assert.is_true(waitFor(function() return not processExists(pid) end, 3))
        end)

        it("should give up when no pipe can be created", function()
            local C = ffi.C
            local fake_C = setmetatable({ pipe = function() return -1 end }, { __index = function(_, k) return C[k] end })
            local restore = setUpvalue(SdcvProcess.new, "C", fake_C)
            finally(restore)
            local warn = spy.on(logger, "warn")
            local proc = SdcvProcess:new({ "/bin/true" })
            assert.is_nil(proc)
            assert.spy(warn).was_called_with("ReaderDictionary: could not create pipe for sdcv:", match._)
            logger.warn:revert()
        end)

        it("should retry reads interrupted by a signal, and give up on read errors", function()
            local C = ffi.C
            local fake_errno
            local nb_eintr = 0
            local fake_C = setmetatable({
                read = function(fd, buf, size)
                    if fake_errno == C.EINTR and nb_eintr < 2 then
                        nb_eintr = nb_eintr + 1
                        return -1
                    elseif fake_errno == C.EINVAL then
                        return -1
                    end
                    return C.read(fd, buf, size)
                end,
            }, { __index = function(_, k) return C[k] end })
            local fake_ffi = setmetatable({
                errno = function() return fake_errno end,
            }, { __index = ffi })
            local restore_C = setUpvalue(SdcvProcess.poll, "C", fake_C)
            local restore_ffi = setUpvalue(SdcvProcess.poll, "ffi", fake_ffi)
            finally(function()
                restore_C()
                restore_ffi()
            end)

            fake_errno = C.EINTR
            local proc = SdcvProcess:new({ "/bin/sh", "-c", "echo hello" })
            proc:wait()
            assert.are.equal(2, nb_eintr)
            assert.are.equal("hello\n", proc:getOutput())

            fake_errno = C.EINVAL
            local warn = spy.on(logger, "warn")
            proc = SdcvProcess:new({ "/bin/sh", "-c", "exec sleep 30" })
            local pid = proc.pid
            assert.is_true(proc:poll()) -- done, as failed
            assert.spy(warn).was_called_with("ReaderDictionary: could not read sdcv output:", match.is_string())
            logger.warn:revert()
            assert.is_nil(proc.fd)
            assert.is_true(waitFor(function() return not processExists(pid) end, 3))
        end)

        it("should work without posix_spawn, forking instead", function()
            local restore = setUpvalue(getUpvalue(SdcvProcess.new, "spawn"), "has_posix_spawn", false)
            finally(restore)
            local completed, output = rd:runSdcv(rd:getSdcvArgs(dict_dir, { "harbor" }, { "Beta" }, false))
            assert.is_true(completed)
            assert.matches("beta: another harbor", output)
            -- An exec failure in the child just gives no output
            local proc = SdcvProcess:new({ tmp .. "/no/such/sdcv" })
            assert.truthy(proc)
            proc:wait()
            assert.are.equal("", proc:getOutput())
        end)

        it("should run the Android sdcv library, with LD_LIBRARY_PATH set only while starting it", function()
            local lib_dir = tmp .. "/android_libs"
            util.makePath(lib_dir)
            os.execute("ln -sf '" .. sdcv_path .. "' '" .. lib_dir .. "/libsdcv.so'")
            local env_calls = {}
            local C = ffi.C
            local fake_C = setmetatable({
                setenv = function(name, value, overwrite)
                    table.insert(env_calls, { "set", name, value, overwrite })
                    return 0
                end,
                unsetenv = function(name)
                    table.insert(env_calls, { "unset", name })
                    return 0
                end,
            }, { __index = function(_, k) return C[k] end })
            local fake_android = { nativeLibraryDir = lib_dir }
            -- (a module local, shared by all its functions)
            local restore_android = setUpvalue(ReaderDictionary.getSdcvArgs, "android", fake_android)
            local restore_C = setUpvalue(SdcvProcess.new, "C", fake_C)
            finally(function()
                restore_C()
                restore_android()
            end)
            local args = rd:getSdcvArgs(dict_dir, { "harbor" }, { "Beta" }, false)
            local completed, output = rd:runSdcv(args)
            assert.are.equal(lib_dir .. "/libsdcv.so", args[1])
            assert.is_true(completed)
            assert.matches("beta: another harbor", output)
            assert.are.same({ { "set", "LD_LIBRARY_PATH", lib_dir, 1 }, { "unset", "LD_LIBRARY_PATH" } }, env_calls)
        end)
    end)
end)
