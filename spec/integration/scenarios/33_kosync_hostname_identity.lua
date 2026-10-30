return {
    name = "KOSync recognizes its own custom hostname without rewinding the reader",
    timeout = 90,
    run = function(T)
        local Client = require("KOSyncClient")
        local Queue = require("KOSyncQueue")
        local Device = require("device")
        local gettext = require("gettext")
        local Server = dofile(T.spec_dir .. "/mock_http_server.lua")
        local server = Server.start(T)
        local function waitSettled()
            T:waitUntil(function() return not Client._active_worker and not Client._pending_worker end,
                10, "KOSync HTTP callbacks finish")
        end
        local function dismiss(message)
            T:waitUntil(function()
                local widget = T:topWidget()
                return widget and widget.text == message
            end, 5, "KOSync status message")
            T:repaint()
            T:tapWidget(T:topWidget())
            T:waitUntil(function() return T:topWidget() == T:reader() end, 5, "status message closes")
        end
        local ok, err = xpcall(function()
            Queue:clear()
            local reader = T:openBook(T:fixture("books/en.epub"))
            local plugin = assert(reader.kosync, "the reader has KOSync attached")
            plugin.settings = require("util").tableDeepCopy(plugin.settings)
            plugin.settings.username, plugin.settings.userkey = "synthetic", "synthetic-key"
            plugin.settings.custom_server, plugin.settings.auto_sync = server.url, false
            plugin.device_id = "synthetic-local-device"
            plugin:registerEvents()
            for _, name in ipairs{ "custom", "default" } do
                plugin.settings.kosync_hostname = name == "custom" and "My reader" or nil
                local published_page = reader:getCurrentPage()
                local put = server:plan(200, { message = "accepted" })
                T:run(function() plugin:updateProgress(false, true) end)
                local request = server:waitReceived(put)
                T:eq(request.method, "PUT", "progress is pushed through the real HTTP client")
                T:eq(request.payload.device, plugin.settings.kosync_hostname or Device.model,
                    name .. " device name is sent to the server")
                T:eq(request.payload.device_id, plugin.device_id, "the stable device ID is sent")
                server:release(put); server:waitFinished(put)
                waitSettled()
                dismiss(gettext("Progress has been pushed."))

                T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
                T:waitUntil(function() return reader:getCurrentPage() > published_page end,
                    5, "reading continues after the push")
                local current_page = reader:getCurrentPage()
                local response = request.payload
                local get = server:plan(200, response)
                T:run(function() plugin:getProgress(false, true) end)
                T:eq(server:waitReceived(get).method, "GET", "progress is manually pulled")
                server:release(get); server:waitFinished(get)
                waitSettled()
                dismiss(gettext("Latest progress is coming from this device."))
                T:eq(reader:getCurrentPage(), current_page, name .. " same-device pull does not rewind the book")

                response.device_id = "synthetic-other-device"
                get = server:plan(200, response)
                T:run(function() plugin:getProgress(false, true) end)
                server:waitReceived(get)
                server:release(get); server:waitFinished(get)
                waitSettled()
                dismiss(gettext("Progress has been synchronized."))
                T:eq(reader:getCurrentPage(), published_page,
                    name .. " matching name with a different ID still syncs the remote position")
            end
            T:closeBook()
        end, debug.traceback)
        local cleanup_ok, cleanup_err = pcall(function()
            for _, job in ipairs(server.jobs) do server:release(job) end
            waitSettled()
            Queue:clear()
            T:closeBook()
        end)
        local server_ok, server_err = pcall(server.close, server)
        if not ok then error(err, 0) end
        if not cleanup_ok then error(cleanup_err, 0) end
        if not server_ok then error(server_err, 0) end
    end,
}
