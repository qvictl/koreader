-- Real menu, JSON decoding, export sinks and native EPUB reader; HTTP is synthetic.
return {
    name = "Wallabag continues past null metadata and preserves successful downloads",
    timeout = 60,
    settings = { language = "en", cover_image_enabled = false, cover_image_fallback = false },
    run = function(T)
        local DocSettings = require("docsettings")
        local InfoMessage = require("ui/widget/infomessage")
        local NetworkMgr = require("ui/network/manager")
        local TouchMenu = require("ui/widget/touchmenu")
        local UIManager = require("ui/uimanager")
        local http = require("socket.http")
        local lfs = require("libs/libkoreader-lfs")
        local util = require("util")
        local plugin = assert(T:fileManager().wallabag)
        local base = os.getenv("KO_HOME") .. "/wallabag-null-metadata"
        local first = base .. "/[w-id_101] First.epub"
        local untitled = base .. "/[w-id_102] .epub"
        local last = base .. "/[w-id_103] Last.epub"
        local menu, summary, infos, requests, exports = nil, nil, {}, 0, {}
        local fail_export = true
        local sink_fault, handles = nil, {}
        local restores, plugin_restores = {}, {}
        local original_config = plugin.wb_settings:readSetting("wallabag")
        local original_server, original_directory = plugin.server_url, plugin.directory
        local function readSettings()
            local file = io.open(plugin.settings_file, "rb")
            if not file then return nil end
            local bytes = file:read("*a")
            file:close()
            return bytes
        end
        local original_settings_bytes = readSettings()
        local function restorePlugin()
            for i = #plugin_restores, 1, -1 do plugin_restores[i]() end
            plugin_restores = {}
        end
        local function override(obj, key, value)
            local old = rawget(obj, key)
            obj[key] = value
            local list = obj == plugin and plugin_restores or restores
            list[#list + 1] = function() obj[key] = old end
        end
        local function closeMessages()
            T:run(function()
                for _, info in ipairs(infos) do
                    if UIManager:isWidgetShown(info) then UIManager:close(info) end
                end
                if menu and UIManager:isWidgetShown(menu) then UIManager:close(menu) end
            end)
        end
        local function sync()
            closeMessages()
            T:run(function()
                local items = {}
                plugin:addToMainMenu(items)
                menu = TouchMenu:new{ width = T.screen_w,
                    tab_item_table = { { icon = "appbar.tools", items.wallabag.sub_item_table[1] } } }
                UIManager:show(menu)
            end)
            T:repaint()
            local item = T:findWidget(menu, function(w)
                return w.item and w.item.text_func and w.item.text_func() == "Download new articles from server"
            end)
            T:tapWidget(item, "download through the real Wallabag menu callback")
            summary = T:topWidget()
            T:check(summary.text and summary.text:find("Sync finished:", 1, true), "sync reaches its real summary")
        end
        local ok, err = pcall(function()
            T:check(not lfs.attributes(base), "private export directory is new")
            assert(util.makePath(base))
            local epub = assert(util.readFromFile(T:fixture("books/en.epub")))
            for key, value in pairs({ directory = base, server_url = "https://wallabag.example.invalid",
                username = "synthetic", password = "synthetic", client_id = "synthetic", client_secret = "synthetic",
                access_token = "synthetic-not-sent", token_expiry = os.time() + 3600,
                filter_tag = "", filter_starred = false, ignore_tags = "", articles_per_sync = 3,
                auto_archive = false, sync_remote_archive = false, download_original_document = true,
                is_dateparser_available = false, offline_queue = {}, updated = false,
            }) do override(plugin, key, value) end
            local real_show = UIManager.show
            override(UIManager, "show", function(manager, widget, ...)
                if getmetatable(widget) == InfoMessage then infos[#infos + 1] = widget end
                return real_show(manager, widget, ...)
            end)
            override(NetworkMgr, "runWhenOnline", function(_, callback) callback() end)
            local real_open = io.open
            override(io, "open", function(path, mode)
                if path ~= untitled or mode ~= "w" or not sink_fault then return real_open(path, mode) end
                local handle = assert(real_open(path, mode))
                local state = { handle = handle, closes = 0 }
                handles[#handles + 1] = state
                return {
                    write = function(_, bytes)
                        if sink_fault == "write" then
                            assert(handle:write(bytes:sub(1, 2)))
                            assert(handle:flush())
                            return nil, "synthetic write ENOSPC"
                        end
                        return handle:write(bytes)
                    end,
                    close = function()
                        state.closes = state.closes + 1
                        local closed, close_err = handle:close()
                        state.closed = true
                        if sink_fault == "close" then return nil, "synthetic close EIO" end
                        return closed, close_err
                    end,
                }
            end)
            override(http, "request", function(request)
                assert(request.method == "GET" and type(request.url) == "string")
                assert(request.headers.Authorization == "Bearer synthetic-not-sent")
                requests = requests + 1
                local bytes, code = epub, 200
                if request.url == "https://wallabag.example.invalid/api/entries.json?archive=0&page=1&perPage=3" then
                    bytes = [[{"pages":1,"_embedded":{"items":[
                        {"id":101,"title":"First","url":"https://example.invalid/a","mimetype":"text/html","tags":[]},
                        {"id":102,"title":null,"url":null,"mimetype":"application/pdf","tags":[]},
                        {"id":103,"title":"Last","url":"https://example.invalid/c","mimetype":"text/html","tags":[]}
                    ]}}]]
                else
                    local id = request.url:match("^https://wallabag%.example%.invalid/api/entries/(10[123])/export%.epub$")
                    assert(id, "unexpected synthetic request: " .. request.url)
                    exports[id] = (exports[id] or 0) + 1
                    if id == "102" and fail_export then bytes, code = "synthetic failure", 503 end
                    if id == "102" and sink_fault == "connect" then return nil, "synthetic connection failure" end
                end
                local written, write_err = request.sink(bytes)
                if not written then return nil, write_err end
                local ended, end_err = request.sink(nil)
                if not ended then return nil, end_err end
                return 1, code, {}, "synthetic HTTP response"
            end)
            sync()
            T:check(summary.text:find("- failed: 1", 1, true), "a failed export is reported without stopping the batch")
            T:eq(requests, 4, "first sync lists once and tries all three exports")
            T:eq(lfs.attributes(untitled), nil, "failed export leaves no misleading local file")
            T:check(assert(util.readFromFile(first)) == epub, "earlier successful article is intact")
            T:check(assert(util.readFromFile(last)) == epub, "later article downloads despite the middle failure")
            local metadata = DocSettings:open(first)
            metadata:saveSetting("annotations", {{ text = "Synthetic highlight", note = "Preserve this note" }})
            assert(metadata:flush())
            local sidecar = assert(DocSettings:findSidecarFile(first))
            local sidecar_bytes = assert(util.readFromFile(sidecar))
            fail_export = false
            for _, fault in ipairs({ "connect", "write", "close" }) do
                sink_fault = fault
                sync()
                T:check(summary.text:find("- failed: 1", 1, true), fault .. " failure is not reported as downloaded")
                T:check(handles[#handles].closed and handles[#handles].closes == 1,
                    fault .. " failure closes its owned file exactly once before returning")
                T:eq(lfs.attributes(untitled), nil, fault .. " failure removes only the unsuccessful export")
                T:check(assert(util.readFromFile(first)) == epub and assert(util.readFromFile(last)) == epub,
                    fault .. " failure does not overwrite earlier successful entries")
                T:eq(assert(util.readFromFile(sidecar)), sidecar_bytes, fault .. " failure preserves previous annotations")
            end
            sink_fault = nil
            sync()
            T:eq(requests, 12, "retry lists once and downloads only the missing entry")
            T:eq(exports["101"], 1, "retry does not overwrite the first success")
            T:eq(exports["102"], 5, "retry uses the untitled entry's unique ID")
            T:eq(exports["103"], 1, "retry does not overwrite the later success")
            T:check(assert(util.readFromFile(untitled)) == epub, "null title and URL produce a valid EPUB export")
            T:eq(assert(util.readFromFile(sidecar)), sidecar_bytes, "retry preserves prior annotations byte-for-byte")
            sync()
            T:eq(requests, 13, "another sync only lists and skips all saved entries")
            T:eq(plugin:getLocalArticles()["102"], untitled, "rescanned inventory recognizes the untitled entry")
            T:run(function() plugin:onFlushSettings() end)
            T:check(plugin.wb_settings:readSetting("wallabag") == original_config,
                "a flush during synthetic configuration does not replace shared settings")
            T:check(readSettings() == original_settings_bytes, "synthetic settings never reach the settings file")
            -- Restore before closing FileManager dispatches FlushSettings and a reader plugin is created.
            restorePlugin()
            closeMessages()
            local ui = T:openBook(untitled)
            T:check(ui.wallabag.server_url == original_server and ui.wallabag.directory == original_directory,
                "new reader plugin inherits the original configuration, not synthetic credentials")
            T:check(ui.document:getPageCount() > 1, "native reader opens the real exported EPUB bytes")
            local page = ui:getCurrentPage()
            T:run(function() ui.rolling:onGotoPage(page + 1) end)
            T:check(ui:getCurrentPage() > page, "the untitled article remains readable and navigable")
            T:closeBook()
            ui = T:openBook(untitled)
            T:check(ui:getCurrentPage() > page, "reader position survives close and reopen")
            T:closeBook()
        end)
        local errors = {}
        local function record(label, passed, failure)
            if not passed then errors[#errors + 1] = label .. ": " .. tostring(type(failure) == "table" and failure.msg or failure) end
        end
        record("scenario", ok, err)
        restorePlugin()
        for _, info in ipairs(infos) do
            record("message cleanup", pcall(function()
                if UIManager:isWidgetShown(info) then T:run(function() UIManager:close(info) end) end
            end))
        end
        record("menu cleanup", pcall(function()
            if menu and UIManager:isWidgetShown(menu) then T:run(function() UIManager:close(menu) end) end
        end))
        record("reader cleanup", pcall(function() T:closeBook() end))
        for i = #restores, 1, -1 do restores[i]() end
        for _, state in ipairs(handles) do
            if not state.closed then
                record("file cleanup", pcall(function() state.handle:close() end))
                state.closed = true
            end
        end
        -- Keep private books until process teardown for queued native work.
        if #errors > 0 then error(table.concat(errors, "\n")) end
        T:check(not T:reader() and T:topWidget() == T:fileManager(), "returns to a usable FileManager")
        local current = T:fileManager().wallabag
        T:check(current.server_url == original_server and current.directory == original_directory,
            "replacement FileManager retains the original Wallabag configuration")
    end,
}
