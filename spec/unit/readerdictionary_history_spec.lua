describe("ReaderDictionary lookup history", function()
    local LuaData, ReaderDictionary, UIManager, util
    local history, original_history, history_index, history_callback, dictionary, menu_items
    local fixture

    setup(function()
        require("commonrequire")
        LuaData = require("luadata")
        ReaderDictionary = require("apps/reader/modules/readerdictionary")
        UIManager = require("ui/uimanager")
        util = require("util")
        fixture = require("datastorage"):getDataDir() .. "/sparse_lookup_history.lua"
    end)

    before_each(function()
        dictionary = setmetatable({ ui = {} }, { __index = ReaderDictionary })
        menu_items = {}
        dictionary:addToMainMenu(menu_items)
        history_callback = menu_items.dictionary_lookup_history.enabled_func
        for i = 1, math.huge do
            local name, value = debug.getupvalue(history_callback, i)
            assert(name, "lookup_history upvalue not found")
            if name == "lookup_history" then
                history_index, original_history = i, value
                break
            end
        end
        history = LuaData:open(fixture, "LookupHistory")
        debug.setupvalue(history_callback, history_index, history)
    end)

    after_each(function()
        debug.setupvalue(history_callback, history_index, original_history)
        for i = #UIManager._window_stack, 1, -1 do
            UIManager:close(UIManager._window_stack[i].widget)
        end
        os.remove(fixture)
        UIManager:quit()
        UIManager._exit_code = nil
    end)

    local function showHistory(entries, expected)
        history.data.lookup_history = entries
        local before = util.tableDeepCopy(entries)
        local lookup = stub(dictionary, "onLookupWord")
        assert.is_true(menu_items.dictionary_lookup_history.enabled_func())
        menu_items.dictionary_lookup_history.callback()
        local stack = UIManager._window_stack
        local page = stack[#stack].widget
        assert.equals("Dictionary lookup history", page.title)
        assert.equals(#expected, #page.kv_pairs)
        for i, row in ipairs(expected) do
            assert.same(row, { page.kv_pairs[i][1], page.kv_pairs[i][2] })
            if page.kv_pairs[i].callback then
                page.kv_pairs[i].callback()
                assert.stub(lookup).was_called_with(dictionary, row[2], true)
            end
        end
        assert.same(before, entries) -- Opening history must not repair/rewrite the stored records.
        return page
    end

    local function entry(word, title, timestamp)
        return { word = word, book_title = title or "Book", time = timestamp or 1764562881 }
    end

    local function date(timestamp)
        return os.date("%Y-%m-%d %H:%M:%S", timestamp or 1764562881)
    end

    it("preserves reverse sequence order, title grouping and callbacks for dense history", function()
        showHistory({ entry("first"), entry("second"), entry("third", "Other") }, {
            { "Other:", "" }, { date(), "third" },
            { "Book:", "" }, { date(), "second" }, { date(), "first" },
        })
    end)

    it("shows append-only records whose sequence starts above one", function()
        -- The upstream report's file starts at 29, with the preceding records lost.
        local data = assert(io.open(fixture, "w"))
        data:write('LookupHistoryEntry{index="lookup_history",data={[29]={word="presumption",book_title="Book",time=1764562881}}}\n')
        data:write('LookupHistoryEntry{index="lookup_history",data={[30]={word="annulment",book_title="Book",time=1764562963}}}\n')
        data:close()
        local contents = assert(util.readFromFile(fixture))
        showHistory(LuaData:open(fixture, "LookupHistory"):readSetting("lookup_history"), {
            { "Book:", "" }, { date(1764562963), "annulment" }, { date(), "presumption" },
        })
        assert.equals(contents, util.readFromFile(fixture))
    end)

    it("keeps entries on both sides of an interior hole", function()
        local entries = { entry("first"), entry("second"), entry("lost"), entry("fourth") }
        entries[3] = nil
        showHistory(entries, {
            { "Book:", "" }, { date(), "fourth" }, { date(), "second" }, { date(), "first" },
        })
    end)

    it("does not lose sparse tail entries or walk the missing index range", function()
        showHistory({ [1] = entry("first"), [1000000000] = entry("last") }, {
            { "Book:", "" }, { date(), "last" }, { date(), "first" },
        })
    end)

    it("can open an empty history table", function()
        showHistory({}, {})
    end)
end)
