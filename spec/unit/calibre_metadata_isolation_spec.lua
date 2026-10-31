describe("Calibre metadata ownership", function()
    local Search, Wireless, wireless, NetworkMgr, Trapper, UIManager, rapidjson, util, lfs
    local tmpdir, inbox, library, saved, responses

    setup(function()
        require("commonrequire")
        NetworkMgr = require("ui/network/manager")
        Trapper = require("ui/trapper")
        UIManager = require("ui/uimanager")
        rapidjson = require("rapidjson")
        util = require("util")
        lfs = require("libs/libkoreader-lfs")
    end)

    local function book(path, title, uuid)
        return { lpath = path, title = title, uuid = uuid, authors = { "Author" },
            tags = { "Tag" }, size = 4, last_modified = "2026-01-01T00:00:00+00:00" }
    end

    local function makeLibrary(path, title, uuid)
        assert(lfs.mkdir(path))
        local file = assert(io.open(path .. "/book.epub", "wb"))
        file:write("book")
        file:close()
        rapidjson.dump(rapidjson.array({ book("book.epub", title, uuid) }), path .. "/.metadata.calibre")
        rapidjson.dump({ device_name = "KOReader", device_store_uuid = uuid }, path .. "/.driveinfo.calibre")
    end

    before_each(function()
        saved = {
            package_path = package.path,
            metadata = package.loaded.metadata, search = package.loaded.search,
            extensions = package.loaded.extensions,
            inbox = G_reader_settings:readSetting("inbox_dir"),
            url = G_reader_settings:readSetting("calibre_wireless_url"),
            network = NetworkMgr.willRerunWhenConnected,
            info = Trapper.info, clear = Trapper.clear, show = UIManager.show,
        }
        tmpdir = os.tmpname()
        os.remove(tmpdir)
        assert(lfs.mkdir(tmpdir))
        inbox, library = tmpdir .. "/inbox", tmpdir .. "/library"
        makeLibrary(inbox, "Inbox book", "inbox-uuid")
        makeLibrary(library, "Library book", "library-uuid")
        package.path = "plugins/calibre.koplugin/?.lua;" .. package.path
        package.loaded.metadata, package.loaded.search, package.loaded.extensions = nil, nil, nil
        Wireless = dofile("plugins/calibre.koplugin/wireless.lua")
        Search = require("search")
        Search.libraries = { [library] = true }
        Search.cache_metadata = false
        responses = {}
        wireless = setmetatable({}, { __index = Wireless })
        wireless:init()
        wireless.initCalibreMQ = function(self)
            self.calibre_socket = { stop = function() end }
        end
        wireless.sendJsonData = function(_, status, data)
            responses[#responses + 1] = { status = status, data = data }
        end
        NetworkMgr.willRerunWhenConnected = function() return false end
        Trapper.info, Trapper.clear = function() end, function() end
        UIManager.show = function() end
        G_reader_settings:saveSetting("inbox_dir", inbox)
        G_reader_settings:saveSetting("calibre_wireless_url", { address = "127.0.0.1", port = 9090 })
        -- Exercise actual connect/metadata initialization and both handshake waits.
        -- The transport alone is synthetic; no remote Calibre or network is used.
        local co = coroutine.create(function() wireless:connect() end)
        for _ = 1, 3 do assert(coroutine.resume(co, true)) end
        assert.are.equal("suspended", coroutine.status(co))
    end)

    after_each(function()
        if wireless and wireless.calibre_socket then wireless:disconnect(true) end
        NetworkMgr.willRerunWhenConnected = saved.network
        Trapper.info, Trapper.clear = saved.info, saved.clear
        UIManager.show = saved.show
        G_reader_settings:saveSetting("inbox_dir", saved.inbox)
        G_reader_settings:saveSetting("calibre_wireless_url", saved.url)
        package.path = saved.package_path
        package.loaded.metadata, package.loaded.search, package.loaded.extensions = saved.metadata, saved.search, saved.extensions
        util.removePath(tmpdir)
    end)

    it("keeps wireless enumeration intact after another library is searched", function()
        local found = Search:getMetadata()
        assert.are.equal("Library book", found[1].title)
        assert.are.equal(library, found[1].rootpath)
        wireless:getBookCount({})
        assert.are.equal(1, responses[1].data.count)
        assert.are.equal("inbox-uuid", responses[2].data.uuid)
    end)

    it("saves incoming metadata to the inbox after searching another library", function()
        local before = assert(util.readFromFile(library .. "/.metadata.calibre"))
        Search:getMetadata()
        wireless:sendBookMetadata{ data = book("book.epub", "Updated inbox", "inbox-uuid"), index = 0, count = 1 }
        local stored = assert(rapidjson.load(inbox .. "/.metadata.calibre"))
        assert.are.equal("Updated inbox", stored[1].title)
        assert.are.equal("inbox-uuid", stored[1].uuid)
        assert.are.equal(before, util.readFromFile(library .. "/.metadata.calibre"))
    end)

    it("saves wireless drive information to the inbox, not the searched library", function()
        local before = assert(util.readFromFile(library .. "/.driveinfo.calibre"))
        Search:getMetadata()
        wireless:setCalibreInfo{ device_store_uuid = "updated-drive" }
        local stored = assert(rapidjson.load(inbox .. "/.driveinfo.calibre"))
        assert.are.equal("updated-drive", stored.device_store_uuid)
        assert.are.equal("KOReader", stored.device_name)
        assert.are.equal(before, util.readFromFile(library .. "/.driveinfo.calibre"))
    end)

    it("does not slim wireless-only identifiers when searching the inbox itself", function()
        Search.libraries = { [inbox] = true }
        local before = assert(util.readFromFile(inbox .. "/.metadata.calibre"))
        local found = Search:getMetadata()
        assert.is_nil(found[1].uuid)
        assert.are.equal(before, util.readFromFile(inbox .. "/.metadata.calibre"))
        wireless:getBookCount({})
        assert.are.equal(1, responses[1].data.count)
        assert.are.equal("inbox-uuid", responses[2].data.uuid)
    end)

    it("keeps search and wireless state separate across repeated searches and reconnect", function()
        for _ = 1, 2 do
            assert.are.equal(1, #Search:getMetadata())
            wireless:sendBookMetadata{ data = book("book.epub", "Still connected", "inbox-uuid"), index = 0, count = 1 }
        end
        wireless:disconnect(true)
        assert.are.equal("Library book", Search:getMetadata()[1].title)
        local co = coroutine.create(function() wireless:connect() end)
        for _ = 1, 3 do assert(coroutine.resume(co, true)) end
        assert.are.equal("suspended", coroutine.status(co))
        assert.are.equal("Library book", Search:getMetadata()[1].title)
        wireless:sendBookMetadata{ data = book("book.epub", "Reconnected", "inbox-uuid"), index = 0, count = 1 }
        assert.are.equal("Reconnected", rapidjson.load(inbox .. "/.metadata.calibre")[1].title)
    end)
    it("finishes receiving a new book after a metadata search", function()
        local before = assert(util.readFromFile(library .. "/.metadata.calibre"))
        Search:getMetadata()
        wireless:sendBook{ lpath = "received.epub", length = 8, thisBook = 0, totalBooks = 1,
            metadata = book("received.epub", "Received", "received-uuid") }
        wireless.calibre_socket.receiveCallback({ "new ", "book" })
        assert.are.equal("new book", util.readFromFile(inbox .. "/received.epub"))
        local stored = assert(rapidjson.load(inbox .. "/.metadata.calibre"))
        assert.are.equal(2, #stored)
        assert.are.equal("inbox-uuid", stored[1].uuid)
        assert.are.equal("received-uuid", stored[2].uuid)
        assert.are.equal(before, util.readFromFile(library .. "/.metadata.calibre"))
    end)

    it("deletes only the inbox book after searching a library with the same lpath", function()
        local before = assert(util.readFromFile(library .. "/.metadata.calibre"))
        Search:getMetadata()
        wireless:deleteBook{ lpaths = { "book.epub" } }
        assert.is_nil(lfs.attributes(inbox .. "/book.epub"))
        assert.are.equal(0, #rapidjson.load(inbox .. "/.metadata.calibre"))
        assert.are.equal("book", util.readFromFile(library .. "/book.epub"))
        assert.are.equal(before, util.readFromFile(library .. "/.metadata.calibre"))
    end)
    describe("ownership edge cases", function()
        it("creates independent JSON arrays and cleans one instance without changing another", function()
            local Metadata = require("metadata")
            local a, b = Metadata:new(), Metadata:new()
            assert.is_not.equal(a.books, b.books)
            assert.is_not.equal(a.drive, b.drive)
            assert.are.equal("[]", rapidjson.encode(a.books))
            a:init(inbox)
            b:init(library, true)
            local keep = b.books
            a:clean()
            assert.are.equal(0, #a.books)
            assert.is_nil(a.metadata)
            assert.are.equal(keep, b.books)
            assert.are.equal("Library book", b.books[1].title)
            assert.are.equal(library .. "/.metadata.calibre", b.metadata)
            assert.are.equal("library-uuid", b.drive.device_store_uuid)
        end)

        for _, kind in ipairs({ "missing", "invalid" }) do
            it("keeps the connection intact after " .. kind .. " search metadata", function()
                local path = library .. "/.metadata.calibre"
                if kind == "missing" then
                    assert(os.remove(path))
                else
                    local f = assert(io.open(path, "w"))
                    f:write("not valid json")
                    f:close()
                end
                local before = util.readFromFile(path)
                assert.are.equal(0, #Search:getMetadata())
                wireless:sendBookMetadata{ data = book("book.epub", "Still valid", "inbox-uuid"), index = 0, count = 1 }
                assert.are.equal("Still valid", rapidjson.load(inbox .. "/.metadata.calibre")[1].title)
                assert.are.equal(before, util.readFromFile(path))
                wireless:getBookCount({})
                assert.are.equal(1, responses[#responses - 1].data.count)
                assert.are.equal("inbox-uuid", responses[#responses].data.uuid)
            end)
        end

        it("keeps both search libraries distinct from a wireless update", function()
            Search.libraries = { [inbox] = true, [library] = true }
            local found = Search:getMetadata()
            assert.are.equal(2, #found)
            local byroot = {}
            for _, item in ipairs(found) do byroot[item.rootpath] = item end
            assert.are.equal("Inbox book", byroot[inbox].title)
            assert.are.equal("Library book", byroot[library].title)
            wireless:sendBookMetadata{ data = book("book.epub", "Inbox update", "inbox-uuid"), index = 0, count = 1 }
            assert.are.equal("Inbox book", byroot[inbox].title)
            assert.are.equal("Library book", byroot[library].title)
            assert.are.equal("Inbox update", rapidjson.load(inbox .. "/.metadata.calibre")[1].title)
            assert.are.equal("Library book", rapidjson.load(library .. "/.metadata.calibre")[1].title)
        end)
    end)

end)
