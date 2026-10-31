-- Use real Calibre connect/metadata/search/transfer handlers and disk files.
-- Only the Calibre transport is synthetic; no server or device is contacted.
return {
    name = "Calibre search does not corrupt an active wireless session",
    timeout = 60,
    settings = { calibre_search_cache_metadata = false },
    run = function(T)
        local DataStorage = require("datastorage")
        local UIManager = require("ui/uimanager")
        local NetworkMgr = require("ui/network/manager")
        local Trapper = require("ui/trapper")
        local util = require("util")
        local lfs = require("libs/libkoreader-lfs")
        local rapidjson = require("rapidjson")
        local original_path = package.path
        package.path = "plugins/calibre.koplugin/?.lua;" .. package.path
        local Wireless = require("wireless")
        local Search = require("search")
        package.path = original_path
        local root = DataStorage:getDataDir() .. "/calibre-isolation"
        local inbox, library = root .. "/inbox", root .. "/library"
        local contents = assert(util.readFromFile(T:fixture("books/en.epub")))
        local function book(path, title, uuid)
            return { lpath = path, title = title, uuid = uuid, authors = { "Synthetic Author" },
                tags = { "Synthetic" }, size = #contents, last_modified = "2026-01-01T00:00:00+00:00" }
        end
        for _, path in ipairs({ inbox, library }) do
            util.makePath(path)
            local file = assert(io.open(path .. "/book.epub", "wb"))
            file:write(contents)
            file:close()
            rapidjson.dump(rapidjson.array({ book("book.epub", path == inbox and "Inbox book" or "Other library book",
                path == inbox and "inbox-uuid" or "other-uuid") }), path .. "/.metadata.calibre")
            rapidjson.dump({ device_name = "KOReader", device_store_uuid = path == inbox and "inbox-drive" or "other-drive" },
                path .. "/.driveinfo.calibre")
        end
        local other_metadata = assert(util.readFromFile(library .. "/.metadata.calibre"))
        local other_drive = assert(util.readFromFile(library .. "/.driveinfo.calibre"))
        local responses = {}
        local wireless = setmetatable({}, { __index = Wireless })
        wireless:init()
        wireless.initCalibreMQ = function(self)
            self.calibre_socket = { stop = function() end }
        end
        wireless.sendJsonData = function(_, status, data)
            responses[#responses + 1] = { status = status, data = data }
        end
        G_reader_settings:saveSetting("inbox_dir", inbox)
        G_reader_settings:saveSetting("calibre_wireless_url", { address = "127.0.0.1", port = 9090 })
        util.makePath(Search.cache_dir)
        assert(Search.cache_libs:save({ [library] = true }))
        local function connect()
            T:run(function()
                local network, info, clear = NetworkMgr.willRerunWhenConnected, Trapper.info, Trapper.clear
                NetworkMgr.willRerunWhenConnected = function() return false end
                Trapper.info, Trapper.clear = function() end, function() end
                local ok, err = pcall(function()
                    local co = coroutine.create(function() wireless:connect() end)
                    for _ = 1, 3 do assert(coroutine.resume(co, true)) end
                    T:eq(coroutine.status(co), "suspended", "wireless connection reaches the heartbeat wait")
                end)
                NetworkMgr.willRerunWhenConnected, Trapper.info, Trapper.clear = network, info, clear
                assert(ok, err)
            end)
        end
        local function search()
            T:run(function()
                Search.books, Search.libraries, Search.search_value = {}, {}, ""
                Search:find("title")
            end)
            T:repaint()
            T:check(UIManager:isWidgetShown(Search.search_menu), "real Calibre results menu is painted")
            T:eq(Search.search_menu.item_table[1].text, "Other library book (1)", "the other library's title is displayed")
            T:run(function() Search.search_menu:onClose() end)
            T:check(not UIManager:isWidgetShown(Search.search_menu), "search menu closes normally")
        end

        connect()
        search()
        T:run(function()
            wireless:sendBookMetadata{ data = book("book.epub", "Updated inbox book", "inbox-uuid"), index = 0, count = 1 }
            wireless:setCalibreInfo{ device_store_uuid = "updated-inbox-drive" }
        end)
        T:eq(rapidjson.load(inbox .. "/.metadata.calibre")[1].title, "Updated inbox book", "incoming metadata updates the connected inbox")
        T:eq(rapidjson.load(inbox .. "/.driveinfo.calibre").device_store_uuid, "updated-inbox-drive", "drive information updates the connected inbox")
        search()
        T:run(function()
            wireless:sendBook{ lpath = "received.epub", length = #contents, thisBook = 0, totalBooks = 1,
                metadata = book("received.epub", "Received book", "received-uuid") }
            wireless.calibre_socket.receiveCallback({ contents })
        end)
        T:check(util.readFromFile(inbox .. "/received.epub") == contents, "received book bytes are preserved")
        T:eq(#rapidjson.load(inbox .. "/.metadata.calibre"), 2, "both old and received books stay in wireless metadata")
        T:run(function() wireless:deleteBook{ lpaths = { "book.epub" } } end)
        T:eq(lfs.attributes(inbox .. "/book.epub"), nil, "wireless deletion removes only the inbox book")
        T:eq(rapidjson.load(inbox .. "/.metadata.calibre")[1].uuid, "received-uuid", "received book metadata survives deletion")
        T:check(util.readFromFile(library .. "/book.epub") == contents, "same-name book in other library is untouched")
        T:eq(util.readFromFile(library .. "/.metadata.calibre"), other_metadata, "other library metadata bytes are untouched")
        T:eq(util.readFromFile(library .. "/.driveinfo.calibre"), other_drive, "other library drive bytes are untouched")
        T:run(function() wireless:disconnect(true) end)
        connect()
        search()
        T:run(function()
            responses = {}
            wireless:getBookCount({})
        end)
        T:eq(responses[1].data.count, 1, "reconnected wireless session still enumerates its book after search")
        T:eq(responses[2].data.uuid, "received-uuid", "wireless UUID survives repeated searches")
        T:run(function() wireless:disconnect(true) end)
        T:run(function()
            for i = #UIManager._window_stack, 1, -1 do
                local widget = UIManager._window_stack[i].widget
                if widget.text and (widget.text:match("^Received file") or widget.text:match("^Deleted file")) then
                    UIManager:close(widget)
                end
            end
        end)
        local ui = T:openBook(inbox .. "/received.epub")
        T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
        T:waitUntil(function() return ui:getCurrentPage() == 2 end, 5, "received EPUB page turn")
        T:check(ui:getCurrentPage() == 2, "received book opens and remains readable")
        T:closeBook()
    end,
}
