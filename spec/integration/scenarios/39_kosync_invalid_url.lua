return {
    name = "Malformed KOSync URLs cannot prevent reading and can be corrected",
    timeout = 90,
    setup = function()
        local DataStorage = require("datastorage")
        local settings = require("luasettings"):open(DataStorage:getSettingsDir() .. "/kosync.lua")
        settings:saveSetting("settings", { username = "synthetic", userkey = "synthetic-key",
            custom_server = "https://", auto_sync = true })
        settings:flush()
    end,
    run = function(T)
        local Client = require("KOSyncClient")
        local Queue = require("KOSyncQueue")
        local NetworkMgr = require("ui/network/manager")
        local Spore = require("Spore")
        local gettext = require("gettext")
        local original_new, original_online = Spore.new_from_spec, NetworkMgr.checkOnline
        local original_rerun, original_run = NetworkMgr.willRerunWhenOnline, NetworkMgr.runWhenOnline
        local attempts = 0
        Spore.new_from_spec = function(...)
            attempts = attempts + 1
            return original_new(...)
        end
        -- Model an online device without external connectivity checks or Wi-Fi prompts.
        NetworkMgr.checkOnline = function(_, callback) callback(true) end
        NetworkMgr.willRerunWhenOnline = function() return false end
        NetworkMgr.runWhenOnline = function(_, callback) callback() end
        local server
        local function dismiss(message)
            T:waitUntil(function()
                local widget = T:topWidget()
                return widget and widget.text == message
            end, 5, "sync failure message")
            T:repaint()
            T:tapWidget(T:topWidget())
            T:waitUntil(function() return T:topWidget() == T:reader() end, 5, "message dismissed")
        end
        local ok, err = xpcall(function()
            Queue:clear()
            local reader = T:openBook(T:fixture("books/en.epub"))
            T:waitUntil(function() return attempts > 0 end, 5, "automatic pull attempts the persisted bad URL")
            local plugin = assert(reader.kosync)
            T:eq(plugin.settings.custom_server, "https://", "saved invalid server is retained, not silently replaced")
            local page = reader:getCurrentPage()
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return reader:getCurrentPage() > page end, 5, "reading works after failed auto-sync")
            page = reader:getCurrentPage()
            local sync_error = gettext("Something went wrong when syncing progress, please check your network connection and try again later.")
            T:run(function() plugin:getProgress(false, true) end)
            dismiss(sync_error)
            T:eq(reader:getCurrentPage(), page, "failed interactive pull does not move the reader")
            local progress = plugin:getLastProgress()
            T:run(function() plugin:updateProgress(false, true) end)
            dismiss(sync_error)
            T:eq(Queue:load()[1].progress, progress, "failed push preserves the latest reading position")

            T:closeBook()
            local before_reopen = attempts
            reader = T:openBook(T:fixture("books/en.epub"))
            plugin = assert(reader.kosync)
            T:waitUntil(function() return attempts > before_reopen end, 5, "queued upload retries safely on reopen")
            T:eq(Queue:count(), 1, "failed reopening drain leaves one queued position")
            T:run(function() plugin:doLogin("replacement-account", "synthetic-password") end)
            dismiss(gettext("Invalid progress sync server address."))
            T:eq(plugin.settings.username, "synthetic", "failed login preserves the current account")

            local items = {}
            plugin:addToMainMenu(items)
            T:run(function() reader.menu:onInput(items.progress_sync.sub_item_table[1].tap_input_func()) end)
            local dialog = reader.menu.input_dialog
            T:run(function() dialog:setInputText("") end)
            T:repaint()
            local button = T:findWidget(dialog, function(w) return w.text == gettext("OK") and w.callback end)
            T:check(button, "the server dialog has an OK button")
            T:tapWidget(button)
            T:waitUntil(function() return T:topWidget() == reader end, 5, "empty URL is accepted and closes the dialog")
            T:eq(plugin.settings.custom_server, nil, "clearing the URL explicitly restores the default")
            local default_client = Client:new{ service_spec = "plugins/kosync.koplugin/api.json" }
            T:check(default_client.client and not default_client.init_error, "the default server constructs without HTTP")

            server = dofile(T.spec_dir .. "/mock_http_server.lua").start(T)
            plugin:setCustomServer(server.url)
            local put = server:plan(200, { message = "accepted" })
            local sent
            T:run(function() plugin:drainQueue(function(count) sent = count end) end)
            T:eq(server:waitReceived(put).payload.progress, progress, "corrected server receives retained progress")
            server:release(put); server:waitFinished(put)
            T:waitUntil(function() return sent ~= nil end, 5, "corrected server drain completes")
            T:eq(sent, 1, "one retained snapshot is uploaded")
            T:eq(Queue:count(), 0, "successful recovery clears the queue")
            plugin.settings.auto_sync = false
            plugin:registerEvents()
            T:closeBook()
        end, debug.traceback)
        local cleanup_ok, cleanup_err = pcall(function()
            if server then server:close() end
            local reader = T:reader()
            if reader and reader.kosync then
                reader.kosync.settings.auto_sync = false
                reader.kosync:registerEvents()
            end
            T:closeBook()
            Queue:clear()
        end)
        Spore.new_from_spec, NetworkMgr.checkOnline = original_new, original_online
        NetworkMgr.willRerunWhenOnline, NetworkMgr.runWhenOnline = original_rerun, original_run
        if not ok then error(err, 0) end
        if not cleanup_ok then error(cleanup_err, 0) end
    end,
}
