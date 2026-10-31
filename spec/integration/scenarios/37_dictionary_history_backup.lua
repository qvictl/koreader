-- Seed synthetic history before ReaderDictionary opens its LuaData instance.
return {
    name = "Dictionary history recovers its newest backup rather than the first-ever snapshot",
    timeout = 60,
    setup = function()
        local DataStorage = require("datastorage")
        local LuaData = require("luadata")
        local path = DataStorage:getSettingsDir() .. "/lookup_history.lua"
        local history = LuaData:open(path, "LookupHistory")
        for generation = 1, 4 do
            history:reset{ lookup_history = {{
                book_title = "Synthetic history",
                time = 1700000000 + generation,
                word = "generation-" .. generation,
            }} }
        end
        local f = assert(io.open(path, "w"))
        f:write("not valid Lua !!!")
        f:close()
    end,
    run = function(T)
        local UIManager = require("ui/uimanager")
        local dictionary = T:fileManager().dictionary
        local menu = {}
        T:run(function() dictionary:addToMainMenu(menu) end)
        T:check(menu.dictionary_lookup_history.enabled_func(), "recovered dictionary history is available")
        T:run(menu.dictionary_lookup_history.callback)
        T:repaint()
        local page = T:topWidget()
        T:check(page and page.kv_pairs, "dictionary history opens in the real history widget")
        T:eq(#page.kv_pairs, 2, "recovered history contains the book header and one lookup")
        T:eq(page.kv_pairs[2][2], "generation-3", "history recovers the latest previous snapshot, not generation-1")
        T:check(page.dimen and page.dimen.w > 0, "recovered dictionary history is painted")
        T:run(function() UIManager:close(page) end)

        -- Exercise the actual deferred lookup-history append after recovery.
        local LuaData = require("luadata")
        local path = require("datastorage"):getSettingsDir() .. "/lookup_history.lua"
        local lfs = require("libs/libkoreader-lfs")
        T:eq(lfs.attributes(path), nil, "corrupt current history was removed during recovery")
        T:run(function() dictionary:onLookupWord("hello", true) end)
        T:waitUntil(function() return lfs.attributes(path, "mode") == "file" end, 5, "lookup persists recovered history")
        local reopened = LuaData:open(path, "LookupHistory"):readSetting("lookup_history")
        T:check(reopened[1] and reopened[1].word == "generation-3", "reopening after lookup retains the recovered entry")
        T:check(reopened[2] and reopened[2].word == "hello", "reopening also retains the newly appended lookup")
        T:run(function()
            if dictionary.dict_window then UIManager:close(dictionary.dict_window) end
        end)
    end,
}
