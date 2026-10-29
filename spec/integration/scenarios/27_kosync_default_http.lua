return {
    name = "Default KOSync HTTP workers preserve UI and response lifetimes",
    timeout = 180,
    run = function(T)
        local ffi = require("ffi")
        local C = ffi.C
        local UI = require("ui/uimanager")
        local ffiUtil = require("ffi/util")
        local NetworkMgr = require("ui/network/manager")
        local Device = require("device")
        local original_wifi = Device.hasWifiManager
        local Client = require("KOSyncClient")
        local Queue = require("KOSyncQueue")
        local Server = dofile(T.spec_dir .. "/mock_http_server.lua")
        local parent = tonumber(C.getpid())
        local server = Server.start(T)
        local original_run, original_done = ffiUtil.runInSubProcess, ffiUtil.isSubProcessDone
        local original_online = NetworkMgr.checkOnline
        local workers, reaped = {}, {}
        local function pipes()
            local count = 0
            for _ in T:fdList():gmatch("=pipe:") do count = count + 1 end
            return count
        end
        ffiUtil.runInSubProcess = function(...)
            local pid, fd = original_run(...)
            if pid then workers[#workers + 1] = pid end
            return pid, fd
        end
        ffiUtil.isSubProcessDone = function(pid, ...)
            local done = original_done(pid, ...)
            if done then reaped[pid] = true end
            return done
        end
        NetworkMgr.checkOnline = function(_, callback) callback(false) end
        local running, previous, gap = true, T:now(), 0
        local function beat()
            local now = T:now()
            gap = math.max(gap, now - previous)
            previous = now
            if running then UI:scheduleIn(0.01, beat) end
        end
        local function reset() gap, previous = 0, T:now() end
        local function responsive(name)
            T:wait(0.05)
            T:budget(name, gap, 800, "ms")
        end
        local function client()
            return Client:new{ custom_url = server.url, service_spec = "plugins/kosync.koplugin/api.json" }
        end
        local function settled()
            return not Client._active_worker and not Client._pending_worker
        end
        local function waitSettled()
            T:waitUntil(settled, 5, "HTTP worker and pending slot settle")
            T:waitUntil(function()
                for _, pid in ipairs(workers) do if not reaped[pid] then return false end end
                return true
            end, 8, "every exact HTTP worker pid is reaped")
        end
        local ok, err = xpcall(function()
            T:check(G_defaults:readSetting("DUSE_TURBO_LIB") == false and UI.looper == nil,
                "the default non-Turbo HTTP path is exercised")
            Queue:clear()
            UI:scheduleIn(0.01, beat)
            local reader = T:openBook(T:fixture("books/en.epub"))
            local baseline_pipes = pipes()
            local result, done
            local get = server:plan(200, { progress = "123", percentage = 0.5 }, 1)
            reset()
            local started = T:now()
            T:run(function()
                client():get_progress("synthetic", "synthetic-key", "synthetic-book", function(success, body)
                    result, done = { success = success, body = body, pid = tonumber(C.getpid()) }, true
                end)
            end)
            local dispatch = T:now() - started
            local synchronous = done
            T:wait(0.05)
            T:budget("default_http_get_dispatch_ms", dispatch, 800, "ms")
            T:check(not synchronous, "GET returns before its slow real HTTP response")
            T:waitUntil(function() return done end, 5, "real GET callback")
            T:check(result.success and result.body.progress == "123", "GET preserves decoded response data")
            T:eq(result.pid, parent, "GET callback runs in the UI parent")
            T:eq(server:waitReceived(get).method, "GET", "the real transport sent a GET")
            server:waitFinished(get)
            waitSettled()
            responsive("default_http_get_heartbeat_ms")

            done, result = false, nil
            local extra = server:plan(200, { progress = "bounded", percentage = 0.75,
                extra = string.rep("x", 128 * 1024) })
            T:run(function()
                client():get_progress("synthetic", "synthetic-key", "extra", function(success, body)
                    result, done = { success = success, body = body }, true
                end)
            end)
            server:waitReceived(extra)
            server:release(extra); server:waitFinished(extra)
            T:waitUntil(function() return done end, 5, "GET with an unknown large response field")
            T:check(result.success and result.body.progress == "bounded" and result.body.percentage == 0.75,
                "known progress fields survive a large unknown HTTP field")
            T:eq(result.body.extra, nil, "unknown HTTP response data does not cross the worker boundary")
            waitSettled()

            done, result = false, nil
            local put = server:plan(200, { message = "accepted" }, 1)
            reset()
            started = T:now()
            T:run(function()
                client():update_progress("synthetic", "synthetic-key", "synthetic-book", nil,
                    "456", 0.6, "Synthetic", "synthetic-device", function(success, status, body)
                        result, done = { success = success, status = status, body = body,
                            pid = tonumber(C.getpid()) }, true
                    end)
            end)
            dispatch = T:now() - started
            synchronous = done
            T:wait(0.05)
            T:budget("default_http_put_dispatch_ms", dispatch, 800, "ms")
            T:check(not synchronous, "PUT returns before its slow real HTTP response")
            T:waitUntil(function() return done end, 5, "real PUT callback")
            T:check(result.success and result.status == 200 and result.body.message == "accepted",
                "PUT keeps its success/status/body callback shape")
            T:eq(result.pid, parent, "PUT callback runs in the UI parent")
            local sent = server:waitReceived(put)
            T:check(sent.method == "PUT" and sent.payload.progress == "456", "the real PUT carries the progress")
            server:waitFinished(put)
            waitSettled()
            responsive("default_http_put_heartbeat_ms")
            T:check(T:reader() == reader, "normal HTTP work keeps the real reader open")
            local function configure(ui, username, auto_sync)
                local plugin = assert(ui.kosync, "the real reader has KOSync attached")
                plugin.settings = require("util").tableDeepCopy(plugin.settings)
                plugin.settings.username, plugin.settings.userkey = username, "synthetic-key"
                plugin.settings.custom_server, plugin.settings.auto_sync = server.url, auto_sync or false
                plugin:registerEvents()
                return plugin
            end
            local function dismissDialogs()
                T:run(function()
                    while T:topWidget() and T:topWidget() ~= T:reader() and T:topWidget() ~= T:fileManager() do
                        UI:close(T:topWidget())
                    end
                end)
            end
            local plugin = configure(reader, "original-account")
            local function authenticate(method, username)
                local Menu = require("ui/widget/menu")
                local menu = Menu:new{ title = "Synthetic account menu", item_table = { { text = "Account" } } }
                local updates, update_pid = 0, nil
                T:run(function() UI:show(menu); UI:forceRePaint() end)
                local update = menu.updateItems
                menu.updateItems = function(self, ...)
                    updates, update_pid = updates + 1, tonumber(C.getpid())
                    return update(self, ...)
                end
                local job = server:plan(method == "doRegister" and 201 or 200, { message = "authorized" })
                reset()
                local before = plugin.settings.username
                T:run(function() plugin[method](plugin, username, "synthetic-password", menu) end)
                local request = server:waitReceived(job)
                T:eq(request.method, method == "doRegister" and "POST" or "GET", "authentication uses real HTTP")
                T:eq(plugin.settings.username, before, "authentication cannot apply before its response")
                server:release(job)
                T:waitUntil(function() return plugin.settings.username == username end, 5, "parent applies authentication")
                waitSettled()
                T:eq(plugin.settings.userkey, require("ffi/sha2").md5("synthetic-password"), "parent saves the authenticated key")
                T:check(updates == 1 and update_pid == parent, "a real shown menu updates only in the parent")
                T:repaint()
                T:check(T:topWidget().text ~= nil, "authentication paints its real result message")
                server:waitFinished(job)
                responsive("default_http_" .. method .. "_heartbeat_ms")
                dismissDialogs()
            end
            authenticate("doRegister", "registered-account")
            authenticate("doLogin", "logged-in-account")
            local first = server:plan(200, { progress = "first" })
            local second = server:plan(200, { message = "second" })
            local first_done, second_done, rejected, rejected_ok
            local count_before = #workers
            T:run(function()
                client():get_progress("synthetic", "key", "first", function(success) first_done = success end)
                client():update_progress("synthetic", "key", "second", nil, "second", 0.1,
                    "Synthetic", "device", function(success) second_done = success end)
                client():get_progress("synthetic", "key", "rejected", function(success)
                    rejected, rejected_ok = true, success
                end)
            end)
            server:waitReceived(first)
            T:check(rejected and rejected_ok == false, "excess progress requests fail without another worker")
            T:eq(#workers, count_before + 1, "only one HTTP worker has started")
            T:check(Client._active_worker and Client._pending_worker, "exactly one progress request is pending")
            T:check(not server:received(second), "pending HTTP is not sent before the active response")
            server:release(first)
            server:waitReceived(second)
            T:eq(#workers, count_before + 2, "the pending request starts after the first worker finishes")
            server:release(second)
            T:waitUntil(function() return first_done and second_done end, 5, "both bounded HTTP requests complete")
            waitSettled()
            server:waitFinished(first); server:waitFinished(second)

            local background = server:plan(200, { progress = "after-page-turn" })
            local background_done, background_ok, background_body
            T:run(function()
                client():get_progress("synthetic", "key", "background", function(success, body)
                    background_done, background_ok, background_body = true, success, body
                end)
            end)
            server:waitReceived(background)
            local page = reader:getCurrentPage()
            T:check(T:topWidget() == reader, "background progress does not cover the reader with a trap")
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h * 0.5))
            T:waitUntil(function() return reader:getCurrentPage() ~= page end, 5, "ordinary tap turns the page during HTTP")
            T:check(not background_done and Client._active_worker ~= nil,
                "ordinary page input leaves the held background HTTP request pending")
            server:release(background); server:waitFinished(background)
            T:waitUntil(function() return background_done end, 5, "background HTTP completes after page input")
            T:check(background_ok and background_body.progress == "after-page-turn",
                "page input cannot cancel the successful progress callback")
            waitSettled()

            local auth_cancel = server:plan(200, { message = "must not apply" })
            local old_username, old_key = plugin.settings.username, plugin.settings.userkey
            T:run(function() plugin:doLogin("cancelled-account", "synthetic-password") end)
            server:waitReceived(auth_cancel)
            T:repaint()
            local cancel_started = T:now()
            T:tapWidget(T:topWidget(), "cancel authentication")
            T:budget("default_http_cancel_ms", T:now() - cancel_started, 800, "ms")
            T:check(plugin.settings.username == old_username and plugin.settings.userkey == old_key,
                "cancelling the busy authentication trap does not write credentials")
            waitSettled()
            server:release(auth_cancel); server:waitFinished(auth_cancel)
            T:check(plugin.settings.username == old_username and plugin.settings.userkey == old_key,
                "cancelled authentication preserves the existing account after its late response")
            authenticate("doLogin", "retried-account")

            local tracked_run = ffiUtil.runInSubProcess
            local failed, failed_ok
            count_before = #workers
            T:run(function()
                ffiUtil.runInSubProcess = function() return false, "synthetic fork failure" end
                client():get_progress("synthetic", "key", "never-sent", function(success)
                    failed, failed_ok = true, success
                end)
                ffiUtil.runInSubProcess = tracked_run
            end)
            T:check(failed and failed_ok == false, "fork failure reports failure without a synchronous network fallback")
            T:eq(#workers, count_before, "fork failure starts no worker")
            T:check(not server:received{ dir = server.root .. "/" .. (#server.jobs + 1) }, "fork failure sends no HTTP request")
            waitSettled()
            Queue:clear()
            plugin = configure(reader, "pending-account")
            local digest = plugin:getDocumentDigest()
            local late = server:plan(202, { message = "retry later" })
            T:run(function() plugin:updateProgress(false, true) end)
            server:waitReceived(late)
            T:run(function() Queue:push{ document = digest, progress = "newer-pending", percentage = 0.9 } end)
            server:release(late); server:waitFinished(late)
            waitSettled()
            T:eq(Queue:load()[1].progress, "newer-pending", "a late failed PUT cannot replace a newer pending snapshot")
            dismissDialogs()

            Queue:clear()
            plugin = configure(reader, "old-account")
            local logout = server:plan(202, { message = "old-account failure" })
            T:run(function() plugin:updateProgress(false, true) end)
            server:waitReceived(logout)
            T:run(function()
                plugin:logout()
                plugin.settings.username, plugin.settings.userkey, plugin.settings.auto_sync = "new-account", "new-key", false
                plugin:registerEvents()
                Queue:push{ document = "new-account-book", progress = "new-account-progress" }
            end)
            server:release(logout); server:waitFinished(logout)
            waitSettled()
            T:check(Queue:count() == 1 and Queue:load()[1].document == "new-account-book",
                "an old-account HTTP failure cannot contaminate the new account queue")
            T:eq(plugin.settings.username, "new-account", "the new account survives the old response")
            dismissDialogs()

            Queue:clear()
            plugin = configure(reader, "manual-close")
            digest = plugin:getDocumentDigest()
            local original_progress = plugin:getLastProgress()
            local manual_close = server:plan(202, { message = "late manual failure" })
            T:run(function() plugin:updateProgress(false, true) end)
            server:waitReceived(manual_close)
            T:closeBook()
            T:eq(Queue:count(), 0, "auto-sync-off close has not queued a new snapshot")
            T:check(Client._active_worker, "real manual HTTP is still held after the reader closes")
            plugin.ui, plugin.view = nil, nil
            server:release(manual_close); server:waitFinished(manual_close)
            waitSettled()
            T:check(Queue:count() == 1 and Queue:load()[1].document == digest
                and Queue:load()[1].progress == original_progress,
                "same-account manual progress survives a late failure after the real reader closes")
            T:check(T:reader() == nil and T:topWidget() == T:fileManager(), "closed-reader callbacks do not paint an error or reopen it")
            Queue:clear()
            reader = T:openBook(T:fixture("books/en.epub"))
            plugin = configure(reader, "automatic-close", true)
            local close_response = server:plan(202, { message = "older failure" })
            T:run(function() plugin:updateProgress(false, true) end)
            server:waitReceived(close_response)
            T:run(function() reader:handleEvent(require("ui/event"):new("GotoPage", reader:getCurrentPage() + 1)) end)
            local closing_progress = plugin:getLastProgress()
            T:closeBook()
            T:eq(Queue:load()[1].progress, closing_progress, "real auto-sync close persists its later progress")
            plugin.ui, plugin.view = nil, nil
            server:release(close_response); server:waitFinished(close_response)
            waitSettled()
            T:check(Queue:count() == 1 and Queue:load()[1].progress == closing_progress,
                "the earlier failed HTTP response does not overwrite real close progress")

            Queue:clear()
            reader = T:openBook(T:fixture("books/en.epub"))
            plugin = configure(reader, "before-auth-close")
            local closed_auth = server:plan(200, { message = "late auth success" })
            T:run(function() plugin:doLogin("stale-auth-account", "synthetic-password") end)
            server:waitReceived(closed_auth)
            T:closeBook()
            T:check(Client._active_worker, "real authentication is still held after the reader closes")
            plugin.ui, plugin.view = nil, nil
            server:release(closed_auth); server:waitFinished(closed_auth)
            waitSettled()
            T:eq(plugin.settings.username, "before-auth-close", "late authentication cannot apply to a closed reader")
            T:check(T:reader() == nil, "late authentication does not restore the old reader")

            Queue:clear()
            reader = T:openBook(T:fixture("books/en.epub"))
            plugin = configure(reader, "suspend-account")
            local suspend = server:plan(200, { message = "accepted old snapshot" })
            T:run(function()
                Device.hasWifiManager = function() return false end
                local online_gate = NetworkMgr.willRerunWhenOnline
                NetworkMgr.willRerunWhenOnline = function() error("suspend must persist without an online gate") end
                plugin.push_timestamp = UI:getElapsedTimeSinceBoot()
                local called, failure = pcall(plugin._onSuspend, plugin)
                NetworkMgr.willRerunWhenOnline = online_gate
                Device.hasWifiManager = original_wifi
                if not called then error(failure, 0) end
            end)
            T:eq(Queue:count(), 1, "suspend persists progress before its real asynchronous HTTP completes")
            server:waitReceived(suspend)
            digest = plugin:getDocumentDigest()
            T:run(function() Queue:push{ document = digest, progress = "latest-close-progress", percentage = 0.95 } end)
            server:release(suspend); server:waitFinished(suspend)
            waitSettled()
            T:check(Queue:count() == 1 and Queue:load()[1].progress == "latest-close-progress",
                "successful suspend HTTP only removes its exact uploaded snapshot")
            responsive("default_http_lifecycle_heartbeat_ms")
            T:closeBook()
            T:eq(pipes(), baseline_pipes, "all HTTP worker pipe readers are closed")
        end, debug.traceback)
        local close_ok, close_error = pcall(function()
            Queue:clear()
            for _, job in ipairs(server.jobs) do server:release(job) end
            local reader = T:reader()
            if reader and reader.kosync then
                reader.kosync.settings.auto_sync = false
                reader.kosync:registerEvents()
            end
            T:closeBook()
        end)
        local workers_ok, workers_error = pcall(function()
            for _, pid in ipairs(workers) do
                if not reaped[pid] then
                    if original_done(pid) then reaped[pid] = true else C.kill(-pid, 9) end
                end
            end
            T:waitUntil(function()
                for _, pid in ipairs(workers) do
                    if not reaped[pid] then
                        if original_done(pid) then reaped[pid] = true else return false end
                    end
                end
                return settled()
            end, 8, "HTTP cleanup reaps workers")
        end)
        local server_ok, server_error = pcall(server.close, server)
        ffiUtil.runInSubProcess, ffiUtil.isSubProcessDone = original_run, original_done
        NetworkMgr.checkOnline = original_online
        Device.hasWifiManager = original_wifi
        running = false
        UI:unschedule(beat)
        if not ok then error(err, 0) end
        if not close_ok then error(close_error, 0) end
        if not workers_ok then error(workers_error, 0) end
        if not server_ok then error(server_error, 0) end
    end,
}
