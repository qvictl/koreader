-- Real Calibre menu, metadata I/O, Trapper notices and ZMQ registration lifecycle.
-- The message queue is an in-memory peer: no socket, DNS or server is used.
return {
    name = "Calibre inbox failures release the connection and allow retry",
    timeout = 60,
    settings = { language = "en", calibre_wireless = true },
    run = function(T)
        local BD = require("ui/bidi")
        local DataStorage = require("datastorage")
        local Device = require("device")
        local NetworkMgr = require("ui/network/manager")
        local TouchMenu = require("ui/widget/touchmenu")
        local Trapper = require("ui/trapper")
        local UIManager = require("ui/uimanager")
        local lfs = require("libs/libkoreader-lfs")
        local rapidjson = require("rapidjson")
        local socket = require("socket")
        local util = require("util")
        local original_path = package.path
        package.path = "plugins/calibre.koplugin/?.lua;" .. package.path
        local Wireless = require("wireless")
        package.path = original_path
        local saved = {
            mq = Wireless.initCalibreMQ, network = NetworkMgr.willRerunWhenConnected,
            dns = socket.dns.getaddrinfo, inbox = G_reader_settings:readSetting("inbox_dir"),
            url = G_reader_settings:readSetting("calibre_wireless_url"),
            double_tap = rawget(Device.input, "disable_double_tap"),
        }
        local root = DataStorage:getDataDir() .. "/calibre-init-error"
        local inbox = root .. "/inbox"
        local ui, menu, owns_root, owns_transport, owns_notice
        local queues, sent = {}, {}
        local standby = UIManager._prevent_standby_count
        local function isRegistered(mq)
            for _, active in ipairs(UIManager._zeromqs) do
                if active == mq then return true end
            end
            return false
        end
        local function retired()
            T:eq(Wireless.calibre_socket, nil, "failed/closed session releases its socket")
            T:eq(Wireless.re, nil, "failed/closed session releases its coroutine resume closure")
            for _, mq in ipairs(queues) do
                T:eq(mq.stopped, 1, "each retired queue is stopped exactly once")
                T:check(not isRegistered(mq), "retired queue is removed from the actual UIManager registry")
            end
            T:eq(UIManager._prevent_standby_count, standby, "wrapped connection releases its standby hold")
        end
        local function menuAction(label)
            local items = {}
            ui.calibre:addToMainMenu(items)
            local entry = items.calibre.sub_item_table[1]
            T:eq(entry.text_func(), label, "Calibre menu reflects connection state")
            T:run(function()
                menu = TouchMenu:new{ width = T.screen_w, tab_item_table = {
                    { icon = "appbar.tools", unpack(items.calibre.sub_item_table) },
                } }
                UIManager:show(menu)
            end)
            T:repaint()
            local row = T:findWidget(menu, function(w) return w.item == entry end)
            T:check(row, "real Calibre " .. label .. " menu item is painted")
            T:tapWidget(row, "Calibre " .. label)
            T:check(not UIManager:isWidgetShown(menu), "Calibre menu closes after activation")
            menu = nil
        end
        local function failConnection()
            local before = #queues
            local started = T:now()
            menuAction("Connect")
            local notice = T:waitUntil(function()
                local widget = T:topWidget()
                return widget and widget.text and widget.text:find("Cannot initialize calibre inbox at ", 1, true) and widget
            end, 3, "local inbox error notice replaces connecting notice")
            T:repaint()
            T:budget("inbox_error_ms", T:now() - started, 5000, "ms")
            T:check(notice.dimen and notice.dimen.w > 0, "local error notice is actually painted")
            T:check(notice.text:find(BD.dirpath(inbox), 1, true), "notice identifies the chosen local inbox")
            T:eq(#queues, before + 1, "one synthetic transport was created for this attempt")
            retired()
            T:eq(#sent, 0, "failed initialization sends no protocol data or parting NOOP")
            T:eq(lfs.attributes(inbox .. "/.metadata.calibre", "mode"), "directory", "bad metadata target is not replaced")
            T:tapWidget(notice, "dismiss local inbox error")
            T:waitUntil(function() return T:topWidget() == ui end, 3, "error notice is dismissed")
        end
        local function receive(opcode, data)
            local json = rapidjson.encode(rapidjson.array({ opcode, data }))
            T:run(function() Wireless.calibre_socket.receiveCallback({ tostring(#json) .. json }) end)
        end
        local function connectSuccessfully()
            menuAction("Connect")
            T:waitUntil(function() return Wireless.calibre_socket ~= nil end, 3, "synthetic transport starts")
            local mq = Wireless.calibre_socket
            T:check(isRegistered(mq), "live synthetic queue is registered with UIManager")
            T:eq(mq.stopped, 0, "successful initialization keeps the transport alive")
            receive(9, { calibre_version = { 9, 0, 0 } })
            receive(3, {})
            T:waitUntil(function() return Trapper.current_widget == nil end, 3, "both handshake responses clear connecting notice")
            T:eq(UIManager._prevent_standby_count, standby + 1, "active connection retains its normal standby hold")
            local first = #sent + 1
            receive(6, {})
            T:eq(sent[first][2].count, 1, "real enumeration sees the repaired inbox book")
            T:eq(sent[first + 1][2].uuid, "inbox-recovery-book", "book identity survives metadata initialization")
            T:eq(rapidjson.load(inbox .. "/.metadata.calibre")[1].title, "Recovered inbox book", "book title survives metadata initialization")
            return mq
        end

        local ok, err = pcall(function()
            T:eq(Wireless.calibre_socket, nil, "scenario starts without a wireless session")
            T:eq(Trapper.current_widget, nil, "scenario owns no pre-existing Trapper message")
            T:eq(lfs.attributes(root), nil, "scenario owns a fresh private inbox root")
            assert(lfs.mkdir(root))
            owns_root, owns_transport, owns_notice = true, true, true
            assert(lfs.mkdir(inbox))
            assert(lfs.mkdir(inbox .. "/.metadata.calibre"))
            local contents = assert(util.readFromFile(T:fixture("books/en.epub")))
            local file = assert(io.open(inbox .. "/book.epub", "wb"))
            assert(file:write(contents))
            assert(file:close())
            Wireless.initCalibreMQ = function(instance)
                local mq = { stopped = 0, waitEvent = function() end, receiveCallback = instance:JSONReceiveCallback() }
                function mq:stop() self.stopped = self.stopped + 1 end
                function mq:send(frame)
                    local start = assert(frame:find("[", 1, true))
                    sent[#sent + 1] = assert(rapidjson.decode(frame:sub(start)))
                end
                queues[#queues + 1] = mq
                instance.calibre_socket = mq
                UIManager:insertZMQ(mq)
            end
            NetworkMgr.willRerunWhenConnected = function() return false end
            socket.dns.getaddrinfo = function() error("Scenario must not probe an external server") end
            G_reader_settings:saveSetting("inbox_dir", inbox)
            G_reader_settings:saveSetting("calibre_wireless_url", { address = "example.invalid", port = 9090 })
            ui = T:openBook(T:fixture("books/en.epub"))
            T:check(ui.calibre, "actual reader Calibre plugin is loaded")
            failConnection()
            failConnection()
            T:check(util.readFromFile(inbox .. "/book.epub") == contents, "failed attempts leave existing book bytes intact")
            local page = ui:getCurrentPage()
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h / 2))
            T:waitUntil(function() return ui:getCurrentPage() > page end, 3, "native page turn still works after failed attempts")

            assert(lfs.rmdir(inbox .. "/.metadata.calibre"))
            rapidjson.dump({ { lpath = "book.epub", title = "Recovered inbox book", uuid = "inbox-recovery-book",
                authors = { "Synthetic Author" }, tags = {}, size = #contents } }, inbox .. "/.metadata.calibre")
            local mq = connectSuccessfully()
            -- Repeated connect while already active is a no-op.
            T:run(function() ui.calibre:onStartWirelessConnection() end)
            T:eq(Wireless.calibre_socket, mq, "duplicate connect retains the existing queue")
            T:eq(#queues, 3, "duplicate connect creates no additional queue")
            menuAction("Disconnect")
            retired()
            T:eq(sent[#sent][1], 12, "normal user disconnect still sends its NOOP")
            connectSuccessfully()
            T:closeBook() -- Actual plugin close hook disconnects the live session.
            retired()
            T:eq(sent[#sent][1], 12, "reader close keeps normal disconnect protocol")
            ui = T:openBook(inbox .. "/book.epub")
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h / 2))
            T:waitUntil(function() return ui:getCurrentPage() == 2 end, 3, "recovered inbox EPUB opens and turns pages")
            T:closeBook()
        end)
        local errors = {}
        if not ok then errors[#errors + 1] = tostring(type(err) == "table" and err.msg or err) end
        local function cleanup(fn)
            local cleaned, failure = pcall(fn)
            if not cleaned then errors[#errors + 1] = tostring(failure) end
        end
        cleanup(function()
            if owns_transport and Wireless.calibre_socket then T:run(function() Wireless:disconnect(true) end) end
        end)
        cleanup(function()
            if menu and UIManager:isWidgetShown(menu) then T:run(function() UIManager:close(menu) end) end
            if owns_notice and Trapper.current_widget then
                T:run(function()
                    if UIManager:isWidgetShown(Trapper.current_widget) then UIManager:close(Trapper.current_widget) end
                    Trapper.current_widget = nil
                end)
            end
        end)
        cleanup(function() T:closeBook() end)
        Wireless.initCalibreMQ, NetworkMgr.willRerunWhenConnected = saved.mq, saved.network
        socket.dns.getaddrinfo = saved.dns
        G_reader_settings:saveSetting("inbox_dir", saved.inbox)
        G_reader_settings:saveSetting("calibre_wireless_url", saved.url)
        Device.input.disable_double_tap = saved.double_tap
        -- The runner owns the isolated profile, including opened-book sidecars.
        -- Leave those artifacts for inspection; never recursively remove unrelated paths.
        if owns_root then T:check(lfs.attributes(root, "mode") == "directory", "private artifacts remain available") end
        if #errors > 0 then error(table.concat(errors, "\n")) end
        T:check(T:topWidget() == T:fileManager(), "all notices and reader windows close back to FileManager")
    end,
}
