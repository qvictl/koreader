-- Dictionary lookups (classic, single sdcv run): exact match in several dictionaries,
-- CJK word, no result (fuzzy and non-fuzzy), and the res/ directory of an HTML dictionary
-- that must be skipped by KOReader's .ifo scan (see 06_sdcv_res_dirs for sdcv itself).
return {
    name = "Dictionary lookup (classic)",
    timeout = 180,
    settings = {
        dict_progressive_lookup = false,
    },
    run = function(T)
        local DictHelper = dofile(T.spec_dir .. "/dicthelper.lua")
        local ui = T:openBook(T:fixture("books/en.epub"))

        -- Distinct dictionaries can share a display name. All must remain selectable.
        local download_menu
        T:run(function()
            for _, item in ipairs(ui.dictionary:_genDownloadDictionariesMenu()) do
                if item.text == "German" then
                    item.callback()
                    download_menu = ui.dictionary.dl_dict_list
                    break
                end
            end
        end)
        T:check(download_menu, "German dictionary downloads open")
        T:repaint()
        local shared_name, urls = 0, {}
        for _, item in ipairs(download_menu.item_table) do
            if item.dict.name == "German-English dictionary" then
                shared_name = shared_name + 1
                urls[item.dict.url] = true
                T:eq(item.mandatory, item.dict.entries, "entry count distinguishes same-name downloads")
            end
        end
        T:eq(shared_name, 3, "all three same-name German-English dictionaries are selectable")
        local distinct_urls = 0
        for _ in pairs(urls) do distinct_urls = distinct_urls + 1 end
        T:eq(distinct_urls, 3, "same-name downloads retain distinct URLs")
        T:run(function() require("ui/uimanager"):close(download_menu) end)

        -- Dictionaries found by KOReader: the 4 fixtures, not the decoy one inside it-gamma/res/.
        T:eq(ui.dictionary:getNumberOfDictionaries(), 4, "number of dictionaries found (res/ skipped)")

        -- Exact match in 3 dictionaries, in dictionary order.
        local r = DictHelper.lookup(T, ui, "harbor")
        T:eq(r.dicts, { "IT Alpha", "IT Beta", "IT Gamma" }, "dictionaries with results for 'harbor'")
        T:check(r.results[1]:find("alpha: definition of harbor", 1, true), "IT Alpha definition")
        T:check(r.window.results[3].is_html, "IT Gamma result is HTML")
        T:check(not r.window.results_pending, "classic lookup is complete at once")
        T:budget("lookup_ms", r.total_ms, 5000, "ms")
        T:eq(r.window.align, "center", "lookup without word boxes is centered")
        local initial_area = r.window:getInitialVisibleArea()
        local painted_area = r.window.dict_frame.dimen
        T:eq({ initial_area.x, initial_area.y, initial_area.w, initial_area.h },
            { painted_area.x, painted_area.y, painted_area.w, painted_area.h },
            "initial dictionary bounds match the painted centered frame")
        DictHelper.close(T, ui)

        -- A word only in one dictionary.
        r = DictHelper.lookup(T, ui, "beacon")
        T:eq(r.dicts, { "IT Beta", "IT Gamma" }, "dictionaries with results for 'beacon'")
        DictHelper.close(T, ui)

        -- CJK word.
        r = DictHelper.lookup(T, ui, "君子")
        T:eq(r.dicts, { "IT Hanzi" }, "dictionaries with results for 君子")
        T:check(r.results[1]:find("才德出眾的人", 1, true), "CJK definition")
        DictHelper.close(T, ui)

        -- No result, fuzzy search enabled: a window saying so.
        r = DictHelper.lookup(T, ui, "qwxzvbnmplk")
        T:check(r.window.results[1].no_result, "no result for a nonsense word")
        DictHelper.close(T, ui)

        -- No result, fuzzy search disabled: the "No results found" dialog, offering fuzzy search.
        ui.dictionary.disable_fuzzy_search = true
        local UIManager = require("ui/uimanager")
        T:run(function() ui.dictionary:onLookupWord("qwxzvbnmplk", true) end)
        local dialog = T:waitUntil(function()
            local top = T:topWidget()
            return top and top.title == "No results found" and top
        end, 20, "the 'No results found' dialog")
        T:run(function() UIManager:close(dialog) end)
        ui.dictionary.disable_fuzzy_search = false

        -- Download two archives with identical booknames through the painted UI.
        -- The URL identity must keep classic and progressive selection independent.
        local util = require("util")
        local ffiUtil = require("ffi/util")
        local DataStorage = require("datastorage")
        local StarDict = dofile(T.spec_dir .. "/../unit/stardict_fixture.lua")
        local http = require("socket.http")
        local original_request = http.request
        local original_rename = os.rename
        local original_disabled = util.tableDeepCopy(ui.dictionary.dicts_disabled)
        local original_order = util.tableDeepCopy(ui.dictionary.dicts_order)
        local source_dir = DataStorage:getDataDir() .. "/same-name-downloads"
        local bodies, entries = {}, {}
        for _, version in ipairs({ "first", "second" }) do
            local dir = source_dir .. "/" .. version
            StarDict.write(dir, version, "IT Shared", { harbor = version .. " shared definition" })
            local archive = source_dir .. "/" .. version .. ".tar.gz"
            local status = os.execute(util.shell_escape({ "tar", "czf", archive, "-C", dir, "." }))
            T:eq(status, 0, "create the synthetic dictionary archive")
            local url = "https://example.com/" .. version .. ".tar.gz"
            bodies[url] = assert(util.readFromFile(archive))
            entries[version] = { name = "German-English dictionary", url = url }
        end
        local ok, err = pcall(function()
            http.request = function(request)
                local body = assert(bodies[request.url], "unexpected dictionary download URL")
                if request.method == "GET" then request.sink(body); request.sink(nil) end
                return 1, 200, { ["content-length"] = tostring(#body) }
            end
            local function download(entry, expected)
                T:run(function() ui.dictionary:downloadDictionary(entry) end)
                local confirm = T:waitUntil(function()
                    local top = T:topWidget()
                    return top and top.ok_text == "Download" and top
                end, 5, "dictionary download confirmation")
                T:repaint()
                local button = T:findWidget(confirm, function(widget)
                    return widget.text == "Download" and widget.callback
                end)
                T:tapWidget(button, "confirm a same-name dictionary download")
                T:waitUntil(function()
                    local top = T:topWidget()
                    return top and top.text and top.text:find(expected, 1, true)
                end, 5, "same-name dictionary installation result")
                T:run(function() UIManager:close(T:topWidget()) end)
            end
            for _, version in ipairs({ "first", "second" }) do
                download(entries[version], "Dictionary downloaded")
            end
            local target = ui.dictionary.data_dir .. "/" .. entries.second.name .. "-"
                .. require("ffi/sha2").md5(entries.second.url)
            local ifo_path = target .. "/second.ifo"
            local ifo_before = assert(util.readFromFile(ifo_path))
            local dictionary_before = assert(util.readFromFile(target .. "/second.dict"))
            local marker = assert(io.open(target .. "/keep", "w")); marker:write("old dictionary"); marker:close()
            local count_before = ui.dictionary:getNumberOfDictionaries()
            T:run(function()
                ui.dictionary.dicts_disabled[ifo_path] = true
                ui.dictionary.dicts_order[ifo_path] = 24
                G_reader_settings:saveSetting("dicts_disabled", ui.dictionary.dicts_disabled)
                G_reader_settings:saveSetting("dicts_order", ui.dictionary.dicts_order)
            end)
            local failures = 0
            rawset(os, "rename", function(source, destination)
                if source:match("%.ifo%.tmp$") then
                    failures = failures + 1
                    return nil, "synthetic UI identity rename failure"
                end
                return original_rename(source, destination)
            end)
            download(entries.second, "synthetic UI identity rename failure")
            rawset(os, "rename", original_rename)
            T:eq(failures, 1, "the metadata rename failure is actually reached")
            T:eq(require("libs/libkoreader-lfs").attributes(target, "mode"), "directory",
                "failed reinstallation retains the previous directory")
            T:eq(assert(util.readFromFile(ifo_path)), ifo_before, "failed reinstallation preserves the old identity bytes")
            T:eq(assert(util.readFromFile(target .. "/second.dict")), dictionary_before,
                "failed reinstallation preserves the old dictionary data")
            T:eq(assert(util.readFromFile(target .. "/keep")), "old dictionary", "failed reinstallation preserves user files")
            T:eq(G_reader_settings:readSetting("dicts_disabled")[ifo_path], true, "failure preserves the disabled setting")
            T:eq(G_reader_settings:readSetting("dicts_order")[ifo_path], 24, "failure preserves the ordering setting")
            download(entries.second, "Dictionary downloaded")
            T:eq(require("libs/libkoreader-lfs").attributes(target .. "/keep"), nil,
                "successful reinstallation replaces the original directory")
            T:eq(ui.dictionary:getNumberOfDictionaries(), count_before, "reinstallation does not create an additional dictionary")
            T:eq(G_reader_settings:readSetting("dicts_disabled")[ifo_path], true, "success preserves the disabled setting")
            T:eq(G_reader_settings:readSetting("dicts_order")[ifo_path], 24, "success preserves the ordering setting")
            local first = "IT Shared [" .. require("ffi/sha2").md5(entries.first.url) .. "]"
            local second = "IT Shared [" .. require("ffi/sha2").md5(entries.second.url) .. "]"
            T:run(function()
                ui.dictionary:loadPreset({ enabled_dict_names = { [second] = true } }, true)
                G_reader_settings:saveSetting("dict_progressive_lookup", false)
            end)
            r = DictHelper.lookup(T, ui, "harbor")
            T:eq(r.dicts, { second }, "classic lookup excludes the disabled same-name version")
            T:check(r.results[1]:find("second shared definition", 1, true), "classic lookup uses the selected source")
            DictHelper.close(T, ui)
            T:run(function()
                ui.dictionary:loadPreset({ enabled_dict_names = { [first] = true, ["IT Beta"] = true } }, true)
                G_reader_settings:saveSetting("dict_progressive_lookup", true)
            end)
            r = DictHelper.lookup(T, ui, "harbor")
            T:check(r.initial_pending, "progressive lookup runs a background dictionary query")
            local names = {}
            for _, name in ipairs(r.dicts) do names[name] = true end
            T:eq(names, { [first] = true, ["IT Beta"] = true }, "progressive lookup excludes the other disabled version")
            T:check(table.concat(r.results, " "):find("first shared definition", 1, true),
                "progressive lookup uses the independently selected source")
            DictHelper.close(T, ui)
        end)
        rawset(os, "rename", original_rename)
        http.request = original_request
        G_reader_settings:saveSetting("dicts_disabled", original_disabled)
        G_reader_settings:saveSetting("dicts_order", original_order)
        ui.dictionary.dicts_disabled = original_disabled
        ui.dictionary.dicts_order = original_order
        ui.dictionary:updateSdcvDictNamesOptions()
        ffiUtil.purgeDir(source_dir)
        if not ok then error(err, 0) end

        -- No sdcv process left behind.
        T:waitUntil(function() return #T:children() == 0 end, 5, "no child process left")
        T:closeBook()
    end,
}
