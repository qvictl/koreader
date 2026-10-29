return {
    name = "Slow DNS keeps the UI responsive and can be cancelled",
    timeout = 30,
    run = function(T)
        local Device = require("device")
        local NetworkMgr = require("ui/network/manager")
        local UIManager = require("ui/uimanager")
        local socket = require("socket")
        local ffi = require("ffi")
        local C = ffi.C
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local base = os.getenv("KO_HOME") .. "/synthetic-dns"
        require("util").makePath(base)
        local saved_toggle, saved_toip = Device.hasWifiToggle, socket.dns.toip
        local saved_before_wifi = NetworkMgr.beforeWifiAction
        local reconnect_calls = 0
        local jobs, heartbeat_count = {}, 0
        local kosync_client, saved_client_new
        local settings_owner, saved_sync_settings, saved_wifi_action
        local heartbeat
        heartbeat = function()
            heartbeat_count = heartbeat_count + 1
            UIManager:scheduleIn(0.01, heartbeat)
        end
        local function pidOf(job)
            local file = io.open(job.entered, "r")
            if not file then return end
            local pid = tonumber(file:read("*a"))
            file:close()
            return pid
        end
        local function start(tag, action, direct, delayed)
            local gate = ffi.new("int[2]")
            assert(C.pipe(gate) == 0)
            local job = { write_fd = tonumber(gate[1]), read_fd = tonumber(gate[0]), entered = base .. "/" .. tag .. ".entered",
                returned = base .. "/" .. tag .. ".returned" }
            jobs[#jobs + 1] = job
            socket.dns.toip = function()
                C.close(gate[1])
                local file = assert(io.open(job.entered, "w"))
                file:write(tostring(tonumber(C.getpid())))
                file:close()
                -- The synthetic resolver cannot finish until the parent releases it.
                local byte = ffi.new("char[1]")
                assert(C.read(gate[0], byte, 1) == 1)
                C.close(gate[0])
                file = assert(io.open(job.returned, "w"))
                file:write("resolved")
                file:close()
                return "192.0.2.1"
            end
            if direct then action() else NetworkMgr:runWhenOnline(action) end
            if not delayed then
                socket.dns.toip = saved_toip
                C.close(gate[0])
                job.read_fd = nil
            end
            job.widget = not delayed and T:topWidget() or nil
            return job
        end
        local function release(job)
            assert(C.write(job.write_fd, "x", 1) == 1)
            C.close(job.write_fd)
            job.write_fd = nil
        end
        local ok, err = pcall(function()
            local calls = 0
            local function guardedAction()
                if NetworkMgr:willRerunWhenOnline(guardedAction) then return end
                calls = calls + 1
            end
            local first
            T:run(function()
                Device.hasWifiToggle = function() return true end
                NetworkMgr.beforeWifiAction = function() reconnect_calls = reconnect_calls + 1 end
                UIManager:scheduleIn(0, heartbeat)
                first = start("success", guardedAction)
            end)
            T:waitUntil(function() return pidOf(first) and heartbeat_count >= 3 end, 5, "DNS waits while UI heartbeats run")
            T:eq(calls, 0, "an unresolved connection does not run the action optimistically")
            T:repaint()
            T:check(first.widget.frame and first.widget.frame.dimen, "the cancellable network check is painted")
            T:run(function() release(first) end)
            T:waitUntil(function() return calls == 1 end, 5, "resolved DNS resumes the guarded action")
            T:eq(calls, 1, "recursive online guard runs once without another resolver")

            local cancelled_calls, cancelled = 0
            local before = heartbeat_count
            T:run(function() cancelled = start("cancelled", function() cancelled_calls = cancelled_calls + 1 end) end)
            T:waitUntil(function() return pidOf(cancelled) and heartbeat_count >= before + 3 end,
                5, "the second resolver waits without freezing the UI")
            T:repaint()
            T:tapWidget(cancelled.widget, "cancel the blocked DNS check")
            -- Keep the gate open: EOF must not let an uncancelled child exit.
            T:waitUntil(function() return ffiUtil.isSubProcessDone(pidOf(cancelled)) end,
                5, "cancel terminates the blocked resolver")
            T:check(not UIManager:isWidgetShown(cancelled.widget), "cancel dismisses the network check")
            T:run(function()
                C.close(cancelled.write_fd)
                cancelled.write_fd = nil
            end)
            T:eq(cancelled_calls, 0, "cancellation does not run the online action")
            T:eq(reconnect_calls, 0, "cancellation does not reconnect Wi-Fi")
            T:eq(lfs.attributes(cancelled.returned), nil, "cancelled resolver cannot publish a late success")

            local next_calls, next_job = 0
            T:run(function() next_job = start("next", function() next_calls = next_calls + 1 end) end)
            T:waitUntil(function() return pidOf(next_job) end, 5, "a fresh check starts after cancellation")
            T:run(function() release(next_job) end)
            T:waitUntil(function() return next_calls == 1 end, 5, "the fresh check completes")
            T:eq(cancelled_calls, 0, "later completions cannot revive the cancelled action")
            T:eq(next_calls, 1, "the new action runs exactly once")
            T:check(heartbeat_count > before, "UI heartbeats continue throughout DNS checks")

            local info_job
            T:run(function()
                local listener = dofile("frontend/ui/network/networklistener.lua")
                info_job = start("info", function() listener:onInfoWifiOn() end, true)
            end)
            T:waitUntil(function() return pidOf(info_job) end, 5, "Wi-Fi info checks DNS asynchronously")
            T:run(function() release(info_job) end)
            T:waitUntil(function()
                return T:topWidget().text == require("gettext")("Already connected.")
            end, 5, "Wi-Fi info reports the resolved connection")
            T:repaint()
            T:check(T:topWidget().dimen, "the Wi-Fi info result is painted")
            T:tapWidget(T:topWidget(), "dismiss Wi-Fi info")

            local article = "https://example.invalid/synthetic-article"
            local added, article_job
            T:run(function()
                local Wallabag = dofile("plugins/wallabag.koplugin/main.lua")
                local plugin = setmetatable({
                    addArticle = function(_, url) added = url; return true end,
                    addToOfflineQueue = function() error("a resolved online article must not queue") end,
                }, { __index = Wallabag })
                article_job = start("article", function() plugin:onAddWallabagArticle(article) end, true)
            end)
            T:waitUntil(function() return pidOf(article_job) end, 5, "Wallabag checks DNS asynchronously")
            T:eq(added, nil, "Wallabag waits for DNS before attempting upload")
            T:run(function() release(article_job) end)
            T:waitUntil(function() return added == article end, 5, "Wallabag continues after DNS resolves")
            T:repaint()
            T:check(T:topWidget().dimen, "the Wallabag result is painted")
            T:tapWidget(T:topWidget(), "dismiss Wallabag result")

            local failed_calls = 0
            T:run(function()
                local run = ffiUtil.runInSubProcess
                ffiUtil.runInSubProcess = function() return nil, "synthetic fork failure" end
                local started, failure = pcall(NetworkMgr.runWhenOnline, NetworkMgr,
                    function() failed_calls = failed_calls + 1 end)
                ffiUtil.runInSubProcess = run
                if not started then error(failure, 0) end
            end)
            T:waitUntil(function()
                return T:topWidget().text == require("gettext")("Network connectivity check failed. Please try again.")
            end, 5, "worker startup failure displays a clear retry message")
            T:repaint()
            T:eq(failed_calls, 0, "worker failure does not run an unverified online action")
            T:eq(reconnect_calls, 0, "worker startup failure does not reconnect Wi-Fi")
            T:check(T:topWidget().dimen, "the worker failure message is painted")
            T:tapWidget(T:topWidget(), "dismiss the failed connectivity check")
            T:run(function()
                socket.dns.toip = function() error("synthetic resolver failure") end
                local started, failure = pcall(NetworkMgr.runWhenOnline, NetworkMgr,
                    function() failed_calls = failed_calls + 1 end)
                socket.dns.toip = saved_toip
                if not started then error(failure, 0) end
            end)
            T:waitUntil(function()
                return T:topWidget().text == require("gettext")("Network connectivity check failed. Please try again.")
            end, 5, "worker task failure is reported instead of silently reconnecting")
            T:repaint()
            T:eq(failed_calls, 0, "a missing worker result cannot run the online action")
            T:eq(reconnect_calls, 0, "a worker task failure is not treated as an offline result")
            T:check(T:topWidget().dimen, "the failed worker result message is painted")
            T:tapWidget(T:topWidget(), "dismiss the failed worker result")

            local Queue = require("KOSyncQueue")
            local sent, held_uploads = {}, nil
            T:run(function()
                Queue:clear()
                kosync_client = require("KOSyncClient")
                saved_client_new = kosync_client.new
                kosync_client.new = function(_, config)
                    return { update_progress = function(_, username, _, document, _, progress, _, _, _, callback)
                        sent[#sent + 1] = { username = username, document = document, progress = progress,
                            server = config.custom_url }
                        if held_uploads then
                            held_uploads[#held_uploads + 1] = callback
                        else
                            callback(true)
                        end
                    end }
                end
            end)
            local function closeWithDNS(tag, username, server)
                local reader = T:openBook(T:fixture("books/en.epub"))
                local plugin, job, expected_progress
                T:run(function()
                    plugin = reader.kosync
                    T:check(plugin, "real KOSync plugin is attached to the reader")
                    plugin.settings = require("util").tableDeepCopy(plugin.settings)
                    plugin.settings.username, plugin.settings.userkey = username, "synthetic-key"
                    plugin.settings.auto_sync = true
                    if server then plugin:setCustomServer(server) end
                    plugin.onCloseDocument = plugin._onCloseDocument
                    expected_progress = plugin:getLastProgress()
                    job = start(tag, function() end, true, true)
                end)
                T:closeBook()
                T:waitUntil(function() return pidOf(job) end, 5, "closed book checks DNS asynchronously")
                T:run(function()
                    C.close(job.read_fd)
                    job.read_fd = nil
                    socket.dns.toip = saved_toip
                    job.widget = T:topWidget()
                end)
                T:check(not require("apps/reader/readerui").instance,
                    "the reader closes before its DNS worker is released")
                return job, plugin, expected_progress
            end
            local closed, old_plugin, expected_progress = closeWithDNS("closed-book", "first")
            T:eq(Queue:count(), 1, "closing persists progress before checking DNS")
            T:eq(Queue:load()[1].progress, expected_progress, "persisted progress comes from the live document")
            T:run(function()
                old_plugin.settings, old_plugin.ui = nil, nil
                for _, method in ipairs{ "getDocumentDigest", "getMetadata", "getLastProgress", "getLastPercent" } do
                    old_plugin[method] = function() error("closed document accessed") end
                end
                release(closed)
            end)
            T:waitUntil(function() return #sent == 1 and Queue:count() == 0 end, 5, "closed book uploads its independent snapshot")
            T:eq(sent[1].progress, expected_progress, "post-close upload uses the persisted progress snapshot")

            local stale, stale_plugin = closeWithDNS("old-account", "first")
            T:run(function()
                stale_plugin:logout()
                Queue:push{ document = "new-account-book", progress = "456" }
                release(stale)
            end)
            T:waitUntil(function() return not UIManager:isWidgetShown(stale.widget) end,
                5, "old account's late DNS check finishes")
            T:eq(#sent, 1, "an old account's resolver cannot send the new queue")
            T:eq(Queue:load()[1].document, "new-account-book", "account switch preserves the new queue")
            local retry = closeWithDNS("new-account", "second")
            T:run(function() release(retry) end)
            T:waitUntil(function() return #sent == 3 and Queue:count() == 0 end, 5, "new account retries its queued progress")
            T:check(sent[2].username == "second" and sent[3].username == "second",
                "the later close drains with only the new account's credentials")

            local old_server, config_plugin = closeWithDNS("old-server", "second")
            local new_server = "https://new-sync.example.invalid"
            T:run(function()
                config_plugin:setCustomServer(new_server)
                Queue:push{ document = "new-server-book", progress = "789" }
                release(old_server)
            end)
            T:waitUntil(function() return not UIManager:isWidgetShown(old_server.widget) end,
                5, "old server's DNS check finishes")
            T:eq(#sent, 3, "an old server's resolver cannot drain newly queued progress")
            T:eq(Queue:count(), 2, "server changes retain all unsent progress")
            local server_retry = closeWithDNS("new-server", "second", new_server)
            T:run(function() release(server_retry) end)
            T:waitUntil(function() return #sent == 5 and Queue:count() == 0 end, 5, "new server retries retained progress")
            T:check(sent[4].server == new_server and sent[5].server == new_server,
                "the retry uses only the new server")

            held_uploads = {}
            local old_http, old_http_plugin = closeWithDNS("http-old-account", "second", new_server)
            T:run(function() release(old_http) end)
            T:waitUntil(function() return #held_uploads == 1 end, 5, "old account upload stays in flight")
            T:run(function() old_http_plugin:logout() end)
            local new_http, active_plugin = closeWithDNS("http-new-account", "third", new_server)
            T:run(function() release(new_http) end)
            T:waitUntil(function() return #held_uploads == 2 end, 5,
                "new account starts uploading before the old response arrives")
            T:check(Queue._draining, "the new account owns an active drain")
            T:run(function() held_uploads[1](true) end)
            T:check(Queue._draining, "the old response cannot release the new account's drain")
            T:eq(Queue:count(), 1, "the old response preserves new account progress")
            T:run(function() held_uploads[2](true) end)
            T:waitUntil(function() return Queue:count() == 0 and not Queue._draining end,
                5, "the new account finishes its independent upload")
            T:eq(sent[#sent].username, "third", "the new upload uses only the new account")
            held_uploads = {}
            T:run(function()
                Queue:push{ document = "active-before-close", progress = "older" }
                active_plugin.settings.custom_server = nil
                active_plugin:drainQueue()
            end)
            T:eq(#held_uploads, 1, "a drain is active before the next real book closes")
            local overlap, overlap_plugin, overlap_progress = closeWithDNS("close-while-draining", "third")
            T:run(function() release(overlap) end)
            T:waitUntil(function() return not UIManager:isWidgetShown(overlap.widget) end,
                5, "the closing resolver completes while the older drain is still active")
            T:eq(#held_uploads, 1, "the closing snapshot waits for the occupied drain")
            T:run(function()
                overlap_plugin.settings, overlap_plugin.ui = nil, nil
                held_uploads[1](true)
            end)
            T:waitUntil(function() return #held_uploads == 2 end,
                5, "the closed book uploads after the older drain without another network event")
            T:eq(sent[#sent].progress, overlap_progress, "the idle retry retains the document-close snapshot")
            T:run(function() held_uploads[2](true) end)
            T:eq(Queue:count(), 0, "both active and closing updates finish")
            held_uploads = nil

            local ready_job, ready_uploads, pull_requests = nil, {}, 0
            local hold_pulls, pending_pulls = false, {}
            local current_digest = sent[1].document
            local remote_progress, remote_percentage = expected_progress, 0
            T:run(function()
                Queue:clear()
                Queue:push{ document = "unrelated-ready-book", progress = "unrelated" }
                Queue:push{ document = current_digest, progress = expected_progress }
                for _, module in ipairs(require("pluginloader").enabled_plugins) do
                    if module.name == "kosync" then
                        settings_owner = module.settings_obj
                        saved_sync_settings = settings_owner:readSetting("settings")
                        local settings = require("util").tableDeepCopy(module.default_settings)
                        settings.auto_sync, settings.username, settings.userkey = true, "second", "synthetic-key"
                        settings.sync_backward, settings.sync_forward = 2, 2
                        settings_owner:saveSetting("settings", settings)
                        break
                    end
                end
                T:check(settings_owner, "KOSync is configured before real ReaderReady")
                saved_wifi_action = G_reader_settings:readSetting("wifi_enable_action")
                G_reader_settings:saveSetting("wifi_enable_action", "turn_on")
                kosync_client.new = function()
                    return {
                        update_progress = function(_, _, _, document, _, progress, percentage, _, _, callback)
                            ready_uploads[#ready_uploads + 1] = { document = document, progress = progress,
                                percentage = percentage, done = function(ok)
                                if ok and document == current_digest then
                                    remote_progress, remote_percentage = progress, percentage
                                end
                                callback(ok)
                            end }
                        end,
                        get_progress = function(_, _, _, _, callback)
                            pull_requests = pull_requests + 1
                            if hold_pulls then
                                pending_pulls[#pending_pulls + 1] = callback
                            else
                                callback(true, { progress = remote_progress, percentage = remote_percentage,
                                    timestamp = 0, device = "Synthetic remote", device_id = "synthetic-remote" })
                            end
                        end,
                    }
                end
                ready_job = start("reader-ready", function() end, true, true)
            end)
            local reopened = T:openBook(T:fixture("books/en.epub"))
            T:waitUntil(function() return pidOf(ready_job) end, 5, "ReaderReady checks DNS before queued progress")
            T:run(function()
                C.close(ready_job.read_fd)
                ready_job.read_fd = nil
                socket.dns.toip = saved_toip
                ready_job.widget = T:topWidget()
                reopened:handleEvent(require("ui/event"):new("GotoPage", 2))
                Queue:push{ document = current_digest, progress = reopened.kosync:getLastProgress(),
                    percentage = reopened.kosync:getLastPercent() }
                release(ready_job)
            end)
            T:waitUntil(function() return #ready_uploads == 1 end, 5, "ReaderReady starts the current book upload first")
            T:eq(ready_uploads[1].document, current_digest, "current book takes priority over unrelated queued failures")
            T:eq(pull_requests, 0, "unfinished upload prevents pulling old remote progress")
            T:eq(reopened:getCurrentPage(), 2, "unfinished upload preserves the visible local position")
            T:run(function() ready_uploads[1].done(false) end)
            T:eq(pull_requests, 0, "failed current-book upload still prevents an old remote pull")
            T:eq(reopened:getCurrentPage(), 2, "failed upload does not overwrite the local position")
            T:run(function() reopened.kosync:_onNetworkConnected() end)
            T:waitUntil(function() return #ready_uploads == 2 end, 5, "a connectivity retry prioritizes current progress again")
            T:eq(ready_uploads[2].progress, reopened.kosync:getLastProgress(), "the retry uploads the fresh page-2 progress")
            T:eq(ready_uploads[2].percentage, reopened.kosync:getLastPercent(), "the retry uploads the fresh page-2 percentage")
            T:run(function() ready_uploads[2].done(true) end)
            T:waitUntil(function() return #ready_uploads == 3 end, 5, "other queued progress is attempted afterwards")
            T:run(function() ready_uploads[3].done(false) end)
            T:waitUntil(function() return pull_requests == 1 end, 5, "other-book failure does not block the current book pull")
            T:eq(reopened:getCurrentPage(), 2, "successful replay and pull retain the fresh local progress")
            T:eq(Queue:load()[1].document, "unrelated-ready-book", "only the unrelated failed record remains queued")
            T:run(function()
                hold_pulls = true
                reopened.kosync:getProgress(false, true)
                reopened.kosync:updateProgress(false, false)
            end)
            T:waitUntil(function() return #ready_uploads == 4 end, 5, "an update runs while a pull response is delayed")
            T:run(function()
                ready_uploads[4].done(false)
                pending_pulls[1](true, { progress = expected_progress, percentage = 0, timestamp = 0,
                    device = "Synthetic remote", device_id = "synthetic-remote" })
            end)
            T:eq(reopened:getCurrentPage(), 2, "a late pull cannot overwrite a newly queued failed upload")
            T:check(Queue:hasPending(current_digest), "the fresh progress remains queued after the late pull")
            T:repaint()
            local blocked_notice = T:topWidget()
            T:eq(blocked_notice.text,
                "Local progress is waiting to be uploaded. Remote progress was not applied.",
                "interactive pull explains why pending local progress was preserved")
            T:run(function() UIManager:close(blocked_notice) end)
            T:run(function() reopened.kosync:drainQueue(nil, current_digest) end)
            T:waitUntil(function() return #ready_uploads == 5 end, 5, "fresh progress can be replayed again")
            T:run(function() ready_uploads[5].done(true) end)
            T:waitUntil(function() return #ready_uploads == 6 end, 5, "unrelated progress is attempted after the current book")
            T:run(function()
                ready_uploads[6].done(false)
                reopened.kosync.settings.sync_backward = 1
                reopened.kosync.pull_timestamp = 0
                reopened.kosync:getProgress(false, false)
                pending_pulls[2](true, { progress = expected_progress, percentage = 0, timestamp = 0,
                    device = "Synthetic remote", device_id = "synthetic-remote" })
            end)
            T:repaint()
            local sync_prompt = T:topWidget()
            T:check(sync_prompt.ok_callback, "the old remote location offers a real sync confirmation")
            T:run(function()
                reopened.kosync.push_timestamp = 0
                reopened.kosync:updateProgress(false, false)
            end)
            T:waitUntil(function() return #ready_uploads == 7 end, 5, "an update runs before the sync prompt is confirmed")
            T:run(function() ready_uploads[7].done(false) end)
            local confirm = T:findWidget(sync_prompt, function(widget)
                return widget.text == sync_prompt.ok_text and widget.callback
            end)
            T:check(confirm and confirm.dimen, "the sync confirmation button is painted")
            T:tapWidget(confirm, "confirm after a failed upload was queued")
            T:eq(reopened:getCurrentPage(), 2, "confirmation rechecks pending uploads before changing local progress")
            T:check(Queue:hasPending(current_digest), "confirmation preserves the unsent local progress")
            T:run(function()
                reopened.kosync:getProgress(false, true)
                reopened.kosync:logout()
                pending_pulls[3](true, { progress = expected_progress, percentage = 0, timestamp = 0,
                    device = "Synthetic old account", device_id = "synthetic-remote" })
            end)
            T:eq(reopened:getCurrentPage(), 2, "an old account pull cannot overwrite the current position after logout")
            T:run(function()
                reopened.kosync.settings.username, reopened.kosync.settings.userkey = "third", "synthetic-new-key"
                reopened.kosync:getProgress(false, true)
                reopened.kosync.settings.auto_sync = false
                reopened.kosync:registerEvents()
            end)
            T:eq(#pending_pulls, 4, "a pull response is held while the actual reader closes")
            T:closeBook()
            T:run(function()
                local handled = pcall(pending_pulls[4], true, { progress = expected_progress,
                    percentage = 0, timestamp = 0, device = "Synthetic remote", device_id = "synthetic-remote" })
                T:check(handled, "a late pull does not access the closed native document")
            end)
            T:check(T:topWidget() == T:fileManager(), "a late pull does not show obsolete reader UI")
        end)
        local cleanup_err
        T:run(function()
            socket.dns.toip, Device.hasWifiToggle = saved_toip, saved_toggle
            NetworkMgr.beforeWifiAction = saved_before_wifi
            UIManager:unschedule(heartbeat)
            if saved_client_new then kosync_client.new = saved_client_new end
            for _, job in ipairs(jobs) do
                if job.widget and UIManager:isWidgetShown(job.widget) then job.widget:_dismissAndResend() end
                local pid = pidOf(job)
                if pid then ffiUtil.terminateSubProcess(pid) end
                if job.write_fd then C.close(job.write_fd) end
                if job.read_fd then C.close(job.read_fd) end
            end
            local reader = require("apps/reader/readerui").instance
            if reader then
                local home_ok, home_err = pcall(function()
                    reader.kosync.settings.auto_sync = false
                    reader.kosync:registerEvents()
                    reader:onHome()
                end)
                if not home_ok then cleanup_err = home_err end
            end
            if settings_owner then
                settings_owner:saveSetting("settings", saved_sync_settings)
                G_reader_settings:saveSetting("wifi_enable_action", saved_wifi_action)
            end
            ffiUtil.purgeDir(base)
        end)
        if not ok then error(err, 0) end
        if cleanup_err then error(cleanup_err, 0) end
    end,
}
