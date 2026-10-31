describe("Cover preferences during custom text metadata edits", function()
    local BookInfo, BookList, DataStorage, Device, DocSettings, UIManager, ffiUtil, lfs, util
    local manager, CoverBrowser, info, file, root, owns_root, saved, props, widgets, freed, events

    setup(function()
        require("commonrequire")
        BookInfo = require("apps/filemanager/filemanagerbookinfo")
        BookList = require("ui/widget/booklist")
        DataStorage = require("datastorage")
        Device = require("device")
        DocSettings = require("docsettings")
        UIManager = require("ui/uimanager")
        ffiUtil = require("ffi/util")
        lfs = require("libs/libkoreader-lfs")
        util = require("util")
    end)

    before_each(function()
        saved = { path = package.path, manager = package.loaded.bookinfomanager,
            show = UIManager.show, close = UIManager.close, broadcast = UIManager.broadcastEvent,
            metadata_folder = G_reader_settings:readSetting("document_metadata_folder"),
            vk = G_reader_settings:readSetting("vk_enabled"),
            start_text = Device.startTextInput, stop_text = Device.stopTextInput }
        manager, info, owns_root = nil, nil, false
        widgets, freed, events = {}, {}, {}
        -- Unit widgets are not placed on the UI stack; keep native input state untouched.
        Device.startTextInput, Device.stopTextInput = function() end, function() end
        G_reader_settings:saveSetting("vk_enabled", false)
        root = DataStorage:getDataDir() .. "/cover-ignore-metadata-unit"
        assert.is_nil(lfs.attributes(root))
        assert(lfs.mkdir(root))
        owns_root = true
        file = root .. "/book.txt"
        local f = assert(io.open(file, "wb"))
        assert(f:write("Private synthetic book.")); assert(f:close())
        package.path = "plugins/coverbrowser.koplugin/?.lua;" .. package.path
        package.loaded.bookinfomanager = nil
        manager = require("bookinfomanager")
        manager.db_location = root .. "/cache.sqlite3"
        CoverBrowser = dofile("plugins/coverbrowser.koplugin/main.lua")
        UIManager.show = function(_, widget) widgets[#widgets + 1] = widget end
        UIManager.close = function(_, widget)
            if not freed[widget] then widget:free(); freed[widget] = true end
        end
        UIManager.broadcastEvent = function(_, event)
            events[#events + 1] = event
            if event.handler == "onInvalidateMetadataCache" then
                CoverBrowser:onInvalidateMetadataCache(unpack(event.args, 1, event.args.n))
            end
        end
        G_reader_settings:saveSetting("document_metadata_folder", "doc")
        manager:openDbConnection()
        local dir, name = util.splitFilePathName(file)
        local stmt = manager.db_conn:prepare([[INSERT INTO bookinfo
            (directory,filename,in_progress,ignore_cover,ignore_meta,has_meta,has_cover,
             cover_fetched,cover_sizetag,cover_w,cover_h,cover_bb_type,cover_bb_stride,cover_bb_data,
             title,authors,series,series_index,language,keywords,description,pages,filesize,filemtime)
            VALUES (?,?,0,'Y','Y','Y','Y','Y','12x16',12,16,0,12,X'01020304',
                    'Original title','Original author','Original series',2,'en','Original keywords','Original description',12,23,456);]])
        stmt:bind(dir, name):step(); stmt:clearbind():reset()
        props = { title = "Original title", authors = "Original author", series = "Original series",
            series_index = 2, language = "en", keywords = "Original keywords", description = "Original description",
            pages = 12, display_title = "Original title" }
        info = BookInfo:new{ ui = {} }
    end)

    after_each(function()
        for _, widget in ipairs(widgets) do
            if not freed[widget] then widget:free(); freed[widget] = true end
        end
        if manager then manager:closeDbConnection() end
        UIManager.show, UIManager.close, UIManager.broadcastEvent = saved.show, saved.close, saved.broadcast
        package.path, package.loaded.bookinfomanager = saved.path, saved.manager
        Device.startTextInput, Device.stopTextInput = saved.start_text, saved.stop_text
        G_reader_settings:saveSetting("vk_enabled", saved.vk)
        G_reader_settings:saveSetting("document_metadata_folder", saved.metadata_folder)
        if owns_root then
            BookList.resetBookInfoCache(file)
            assert(ffiUtil.purgeDir(root))
        end
    end)

    local function row()
        local r = table.pack(manager.db_conn:rowexec([[SELECT bcid,ignore_cover,ignore_meta,hex(cover_bb_data),
            in_progress,has_cover,cover_fetched,filesize,filemtime FROM bookinfo;]]))
        return r[1] and r or nil
    end

    local function edit(key, value)
        info:show(file, props)
        info:setCustomMetadata(file, props, key, value)
    end

    local changes = { title = "Custom title", authors = "Custom author\nSecond author", series = "Custom series",
        series_index = 3.5, language = "ja", keywords = "Custom keywords", description = "Custom description" }
    for _, key in ipairs({ "title", "authors", "series", "series_index", "language", "keywords", "description" }) do
        for _, flags in ipairs({ { "Y", "Y" }, { "Y", false }, { false, "Y" }, { false, false } }) do
            it("preserves independent ignore choices when editing " .. key .. " (" .. tostring(flags[1]) .. "," .. tostring(flags[2]) .. ")", function()
                manager:setBookInfoProperties(file, { ignore_cover = flags[1], ignore_meta = flags[2] })
                local before = row()
                edit(key, changes[key])
                local cached = assert(manager:getBookInfo(file))
                assert.are.equal(changes[key], cached[key])
                assert.are.equal(flags[1] or nil, cached.ignore_cover)
                assert.are.equal(flags[2] or nil, cached.ignore_meta)
                assert.are.equal(changes[key], BookInfo.getCustomProp(key, file))
                assert.same(before, row()) -- Same row, cover bytes and user preferences.
                assert.are.equal(2, #events)
                assert.are.equal("onInvalidateMetadataCache", events[1].handler)
                assert.are.equal(key, events[1].args[2])
                assert.are.equal(changes[key], events[1].args[3])
                assert.are.equal("onBookMetadataChanged", events[2].handler)
                assert.are.equal(key, events[2].args[1].metadata_key_updated)
            end)
        end
    end

    it("keeps flags and updated values across DB close/reopen and repeated edits", function()
        local before = row()
        edit("title", changes.title)
        manager:closeDbConnection()
        manager:openDbConnection()
        edit("authors", changes.authors)
        manager:closeDbConnection()
        local cached = assert(manager:getBookInfo(file))
        assert.are.equal(changes.title, cached.title)
        assert.are.equal(changes.authors, cached.authors)
        assert.same(before, row())
    end)

    it("restores an original value when resetting custom metadata without resetting flags", function()
        local before = row()
        edit("title", changes.title)
        info:setCustomMetadata(file, props, "title", nil)
        local cached = assert(manager:getBookInfo(file))
        assert.are.equal("Original title", cached.title)
        assert.is_nil(DocSettings:findCustomMetadataFile(file))
        assert.same(before, row())
        assert.are.equal("Original title", events[3].args[3])
    end)

    it("clears a field back to SQL NULL when the original value was absent", function()
        props.language = nil
        manager:setBookInfoProperties(file, { language = false })
        local before = row()
        edit("language", changes.language)
        info:setCustomMetadata(file, props, "language", nil)
        assert.is_nil(manager:getBookInfo(file).language)
        assert.same(before, row())
        assert.are.equal(3, events[3].args.n)
        assert.is_nil(events[3].args[3])
    end)

    it("does not invent a completed cache row for an uncached book", function()
        manager:deleteBookInfo(file)
        edit("title", changes.title)
        assert.is_nil(manager:getBookInfo(file))
        assert.is_nil(row())
        assert.are.equal(changes.title, BookInfo.getCustomProp("title", file))
    end)

    it("does not mark an incomplete extraction as complete", function()
        manager:setBookInfoProperties(file, { in_progress = 2 })
        local before = row()
        edit("title", changes.title)
        assert.is_nil(manager:getBookInfo(file))
        assert.same(before, row())
        assert.are.equal(changes.title, manager.db_conn:rowexec("SELECT title FROM bookinfo;"))
    end)

    it("preserves full invalidation for custom cover changes", function()
        info:show(file, props)
        info:updateBookInfo(file, props, "cover")
        assert.is_nil(manager:getBookInfo(file))
        assert.is_nil(row())
        assert.are.equal("cover", events[1].args[2])
    end)

    it("preserves callers requesting full invalidation without metadata arguments", function()
        assert.is_true(CoverBrowser:onInvalidateMetadataCache(file))
        assert.is_nil(manager:getBookInfo(file))
        assert.is_nil(row())
    end)

    it("preserves explicit cache deletion semantics", function()
        manager:deleteBookInfo(file)
        assert.is_nil(manager:getBookInfo(file))
        assert.is_nil(row())
    end)

    it("does not alter cache or saved metadata when the edit dialog is cancelled", function()
        local before = row()
        info:show(file, props)
        info:showCustomEditDialog(file, props, "title")
        local dialog
        for _, widget in ipairs(widgets) do
            if widget._input_widget then dialog = widget end
        end
        assert.is_not_nil(dialog)
        dialog:setInputText(changes.title)
        dialog.buttons[1][1].callback()
        assert.same(before, row())
        assert.are.equal("Original title", manager:getBookInfo(file).title)
        assert.is_nil(DocSettings:findCustomMetadataFile(file))
        assert.same({}, events)
    end)
end)
