describe("Calibre inbox initialization failures", function()
    local DataStorage, NetworkMgr, Trapper, UIManager, lfs, rapidjson, socket, util
    local Metadata, Search, wireless, metadata, root, owns_root, inbox, saved, calls, notices, responses

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        NetworkMgr = require("ui/network/manager")
        Trapper = require("ui/trapper")
        UIManager = require("ui/uimanager")
        lfs = require("libs/libkoreader-lfs")
        rapidjson = require("rapidjson")
        socket = require("socket")
        util = require("util")
    end)

    before_each(function()
        saved = {
            path = package.path, metadata = package.loaded.metadata,
            search = package.loaded.search, extensions = package.loaded.extensions,
            inbox = G_reader_settings:readSetting("inbox_dir"),
            url = G_reader_settings:readSetting("calibre_wireless_url"),
            network = NetworkMgr.willRerunWhenConnected, connected = NetworkMgr.isConnected,
            info = Trapper.info, clear = Trapper.clear,
            remove = UIManager.removeZMQ, schedule = UIManager.scheduleIn,
            dns = socket.dns.getaddrinfo,
        }
        root = DataStorage:getDataDir() .. "/calibre-init-error-unit"
        owns_root = false
        assert.is_nil(lfs.attributes(root))
        assert(lfs.mkdir(root))
        owns_root = true
        inbox = root .. "/inbox"
        assert(lfs.mkdir(inbox))
        package.path = "plugins/calibre.koplugin/?.lua;" .. package.path
        package.loaded.metadata, package.loaded.search, package.loaded.extensions = nil, nil, nil
        Metadata, Search = require("metadata"), require("search")
        local original_init = Metadata.init
        Metadata.init = function(self, ...)
            metadata = self
            calls.init = calls.init + 1
            return original_init(self, ...)
        end
        local Wireless = dofile("plugins/calibre.koplugin/wireless.lua")
        wireless = setmetatable({}, { __index = Wireless })
        wireless:init()
        metadata = nil
        calls = { started = 0, stopped = 0, removed = 0, invalidated = 0, init = 0, clear = 0, waits = {} }
        notices, responses = {}, {}
        wireless.initCalibreMQ = function(self)
            calls.started = calls.started + 1
            self.calibre_socket = { stop = function() calls.stopped = calls.stopped + 1 end }
        end
        wireless.sendJsonData = function(_, status, data)
            responses[#responses + 1] = { status = status, data = data }
        end
        Search.invalidateCache = function() calls.invalidated = calls.invalidated + 1 end
        UIManager.removeZMQ = function(_, mq)
            assert.are.equal(wireless.calibre_socket, mq)
            calls.removed = calls.removed + 1
        end
        UIManager.scheduleIn = function(manager, delay, action)
            calls.waits[#calls.waits + 1] = delay
            return saved.schedule(manager, delay, action)
        end
        NetworkMgr.willRerunWhenConnected = function() return false end
        Trapper.info = function(_, text) notices[#notices + 1] = text end
        Trapper.clear = function() calls.clear = calls.clear + 1 end
        socket.dns.getaddrinfo = function() error("Unexpected network diagnostic") end
        G_reader_settings:saveSetting("inbox_dir", inbox)
        G_reader_settings:saveSetting("calibre_wireless_url", { address = "example.invalid", port = 9090 })
    end)

    after_each(function()
        if wireless and wireless.calibre_socket then wireless:disconnect(true) end
        NetworkMgr.willRerunWhenConnected, NetworkMgr.isConnected = saved.network, saved.connected
        Trapper.info, Trapper.clear = saved.info, saved.clear
        UIManager.removeZMQ, UIManager.scheduleIn = saved.remove, saved.schedule
        socket.dns.getaddrinfo = saved.dns
        G_reader_settings:saveSetting("inbox_dir", saved.inbox)
        G_reader_settings:saveSetting("calibre_wireless_url", saved.url)
        package.path = saved.path
        package.loaded.metadata, package.loaded.search, package.loaded.extensions = saved.metadata, saved.search, saved.extensions
        if not owns_root then return end
        -- Only remove files/directories created by this fixture; never climb parents.
        for _, name in ipairs({ "inbox", "replacement" }) do
            local dir = root .. "/" .. name
            if lfs.attributes(dir) then
                for _, filename in ipairs({ ".metadata.calibre", ".driveinfo.calibre", "book.epub" }) do
                    local path = dir .. "/" .. filename
                    local mode = lfs.attributes(path, "mode")
                    if mode == "directory" then
                        assert(lfs.rmdir(path))
                    elseif mode then
                        assert(os.remove(path))
                    end
                end
                assert(lfs.rmdir(dir))
            end
        end
        assert(lfs.rmdir(root))
    end)

    local function resume(co, value)
        local ok, err = coroutine.resume(co, value)
        assert.is_true(ok, tostring(err))
    end

    local function connect()
        local co = coroutine.create(function() wireless:connect() end)
        resume(co)
        return co
    end

    local function blockMetadata()
        assert(lfs.mkdir(inbox .. "/.metadata.calibre"))
    end

    local function assertRetired()
        assert.is_nil(wireless.calibre_socket)
        assert.is_nil(wireless.re)
        assert.is_false(wireless.invalid_password)
        assert.is_false(wireless.disconnected_by_server)
        assert.are.equal(calls.started, calls.stopped)
        assert.are.equal(calls.started, calls.removed)
        assert.are.equal(calls.started, calls.invalidated)
        assert.same({}, responses) -- Never send a parting NOOP after failed initialization.
        assert.is_nil(metadata.path)
        assert.is_nil(metadata.metadata)
        assert.is_nil(metadata.driveinfo)
        assert.are.equal("[]", rapidjson.encode(metadata.books))
        assert.are.equal("[]", rapidjson.encode(metadata.drive))
    end

    local function assertInboxNotice()
        assert.truthy(notices[#notices]:find("Cannot initialize calibre inbox at ", 1, true))
        assert.truthy(notices[#notices]:find(inbox, 1, true))
        assert.is_nil(notices[#notices]:find("Cannot connect to calibre server", 1, true))
    end

    local function finishHandshake(co)
        assert.are.equal("suspended", coroutine.status(co))
        resume(co, true)
        resume(co, true)
        assert.are.equal("suspended", coroutine.status(co))
        assert.are.equal(1, calls.clear)
        assert.same({ 5, 1, 300 }, calls.waits)
    end

    it("contains a native metadata-open error and retires the transport without probing the server", function()
        blockMetadata()
        assert.are.equal("dead", coroutine.status(connect()))
        assert.are.equal(1, calls.started)
        assertRetired()
        assertInboxNotice()
        assert.same({}, calls.waits)
        assert.are.equal("directory", lfs.attributes(inbox .. "/.metadata.calibre", "mode"))
    end)

    it("cleans connection and partial metadata before a yielding error notice", function()
        blockMetadata()
        local info = Trapper.info
        Trapper.info = function(self, text)
            info(self, text)
            if text:find("Cannot initialize calibre inbox", 1, true) then
                assertRetired()
                coroutine.yield()
            end
        end
        local co = connect()
        assert.are.equal("suspended", coroutine.status(co))
        assertRetired()
        resume(co)
        assert.are.equal("dead", coroutine.status(co))
    end)

    it("can retry a still-invalid inbox without accumulating transports", function()
        blockMetadata()
        for n = 1, 3 do
            assert.are.equal("dead", coroutine.status(connect()))
            assert.are.equal(n, calls.started)
            assertRetired()
            assertInboxNotice()
        end
        assert.same({}, calls.waits)
    end)

    it("connects after the same inbox's metadata target is repaired", function()
        blockMetadata()
        connect()
        assertRetired()
        assert(lfs.rmdir(inbox .. "/.metadata.calibre"))
        finishHandshake(connect())
        assert.are.equal(2, calls.started)
        assert.are.equal(1, calls.stopped)
        assert.are.equal(inbox, metadata.path)
        assert.are.equal("[]", util.readFromFile(inbox .. "/.metadata.calibre"))
    end)

    it("connects to a different chosen inbox without retaining the failed path", function()
        blockMetadata()
        connect()
        local bad = inbox
        inbox = root .. "/replacement"
        assert(lfs.mkdir(inbox))
        G_reader_settings:saveSetting("inbox_dir", inbox)
        finishHandshake(connect())
        assert.are.equal(inbox .. "/.metadata.calibre", metadata.metadata)
        assert.are.equal("directory", lfs.attributes(bad .. "/.metadata.calibre", "mode"))
    end)

    it("cleans loaded books and drive data when initialization fails during save", function()
        local file = assert(io.open(inbox .. "/book.epub", "wb"))
        file:write("book")
        file:close()
        rapidjson.dump({ { lpath = "book.epub", title = "Book", uuid = "book-uuid" } }, inbox .. "/.metadata.calibre")
        rapidjson.dump({ device_name = "KOReader", device_store_uuid = "drive-uuid" }, inbox .. "/.driveinfo.calibre")
        Metadata.saveBookList = function(self)
            assert.are.equal("book-uuid", self.books[1].uuid)
            assert.are.equal("drive-uuid", self.drive.device_store_uuid)
            error("Synthetic metadata save failure")
        end
        assert.are.equal("dead", coroutine.status(connect()))
        assertRetired()
        assertInboxNotice()
        assert.are.equal("Book", rapidjson.load(inbox .. "/.metadata.calibre")[1].title)
    end)

    it("also contains a non-string initialization error", function()
        Metadata.saveBookList = function() error({ kind = "synthetic" }) end
        assert.are.equal("dead", coroutine.status(connect()))
        assertRetired()
        assertInboxNotice()
    end)

    it("still initializes an empty writable inbox and completes both handshake waits", function()
        finishHandshake(connect())
        assert.are.equal(1, calls.init)
        assert.are.equal(0, calls.stopped)
        assert.are.equal("[]", util.readFromFile(inbox .. "/.metadata.calibre"))
        assert.are.equal(1, #notices)
    end)

    it("preserves valid metadata enumeration on successful connection", function()
        local file = assert(io.open(inbox .. "/book.epub", "wb"))
        file:write("book")
        file:close()
        rapidjson.dump({ { lpath = "book.epub", title = "Book", uuid = "book-uuid" } }, inbox .. "/.metadata.calibre")
        finishHandshake(connect())
        wireless:getBookCount({})
        assert.are.equal(1, responses[1].data.count)
        assert.are.equal("book-uuid", responses[2].data.uuid)
    end)

    for stage = 1, 2 do
        it("preserves cancellation during handshake wait " .. stage, function()
            local co = connect()
            if stage == 2 then resume(co, true) end
            resume(co, false)
            assert.are.equal("dead", coroutine.status(co))
            assertRetired()
            assert.are.equal(1, #notices)
            assert.are.equal(0, calls.clear)
        end)
    end

    it("ignores duplicate connection requests while connected", function()
        finishHandshake(connect())
        wireless:connect()
        assert.are.equal(1, calls.started)
        assert.are.equal(1, calls.init)
    end)

    it("keeps transport failures separate from metadata failures", function()
        wireless.initCalibreMQ = function() error("Synthetic transport failure") end
        local probes = 0
        socket.dns.getaddrinfo = function()
            probes = probes + 1
            return nil, "Synthetic DNS failure"
        end
        assert.are.equal("dead", coroutine.status(connect()))
        assert.are.equal(1, probes)
        assert.are.equal(0, calls.init)
        assert.truthy(notices[#notices]:find("Cannot connect to calibre server", 1, true))
        assert.is_nil(metadata)
    end)

    it("contains the same native error after the inbox chooser resumes", function()
        blockMetadata()
        G_reader_settings:delSetting("inbox_dir")
        local choose
        wireless.setInboxDir = function(_, cb) choose = cb end
        local co = connect()
        assert.are.equal(0, calls.started)
        assert.are.equal("suspended", coroutine.status(co))
        choose(inbox)
        assert.are.equal("dead", coroutine.status(co))
        assertRetired()
        assertInboxNotice()
    end)

    it("does not initialize metadata if the network request is cancelled", function()
        NetworkMgr.willRerunWhenConnected = function() return true end
        NetworkMgr.isConnected = function() return false end
        local co = connect()
        assert.are.equal("suspended", coroutine.status(co))
        resume(co)
        assert.are.equal("dead", coroutine.status(co))
        assert.are.equal(0, calls.started)
        assert.are.equal(0, calls.init)
        assert.same({}, notices)
    end)
end)
