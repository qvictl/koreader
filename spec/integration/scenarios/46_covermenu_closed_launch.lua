return {
    name = "Closing a cover menu cancels its deferred extraction launch",
    timeout = 60,
    run = function(T)
        local BookInfoManager = require("bookinfomanager")
        local ReadCollection = require("readcollection")
        local UIManager = require("ui/uimanager")
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local util = require("util")
        local fm = T:fileManager()
        local manager = fm.collections
        local base = os.getenv("KO_HOME") .. "/closed-cover-menu"
        local file = base .. "/synthetic.epub"
        local saved = {
            coll = ReadCollection.coll,
            settings = ReadCollection.coll_settings,
            dirty = manager.updated_collections,
            menu = manager.booklist_menu,
            match = manager.match_table,
            selected = manager.selected_files,
            extract = BookInfoManager.extractInBackground,
        }
        local launches = 0
        assert(not lfs.attributes(base), "scenario fixture directory must be new")
        local ok, err = pcall(function()
            T:waitUntil(function() return not BookInfoManager:isExtractingInBackground() end, 15, "startup extraction finishes")
            T:run(function()
                util.makePath(base)
                assert(not ffiUtil.copyFile(T:fixture("books/en.epub"), file))
                ReadCollection.coll = { favorites = {} }
                ReadCollection.coll_settings = util.tableDeepCopy(saved.settings)
                manager.updated_collections = {}
                ReadCollection:addItem(file, "favorites", lfs.attributes(file))
                BookInfoManager.extractInBackground = function(self, files)
                    for _, item in ipairs(files) do
                        if item.filepath == file then launches = launches + 1 end
                    end
                    return saved.extract(self, files)
                end
            end)

            for attempt = 1, 2 do
                local closed
                T:run(function()
                    manager:onShowColl("favorites")
                    closed = manager.booklist_menu
                    assert(closed._coverbrowser_overridden, "actual cover-browser menu must be enabled")
                    assert(#closed.items_to_update > 0, "uncached fixture must queue extraction")
                    manager.booklist_menu.close_callback() -- before nextTick can run
                    closed:onCloseWidget() -- repeated lifecycle notification is harmless
                end)
                T:wait() -- drain the real nextTick task queue
                T:eq(launches, 0, "closed menu does not launch extraction, attempt " .. attempt)
                T:eq(closed.items_update_action, nil, "closed menu has no update polling action")
                T:check(T:topWidget() == fm, "dismissed menu leaves the file manager visible")
            end

            T:run(function() manager:onShowColl("favorites") end)
            T:repaint()
            T:waitUntil(function() return launches == 1 end, 5, "open menu launches extraction")
            T:check(manager.booklist_menu.dimen ~= nil, "open cover menu paints")
            T:waitUntil(function()
                return BookInfoManager:getBookInfo(file) ~= nil
            end, 10, "real child extracts synthetic book metadata")
            local bookinfo = BookInfoManager:getBookInfo(file)
            T:eq(bookinfo.has_meta, "Y", "native child successfully extracts metadata")
            T:eq(bookinfo.title, "Integration Test Book", "extracted title matches the synthetic EPUB")
            T:eq(launches, 1, "open menu starts exactly one native extraction")
            T:run(function() manager.booklist_menu.close_callback() end)
            T:waitUntil(function() return not BookInfoManager:isExtractingInBackground() end, 15, "closed menu worker is reaped")
            T:check(T:topWidget() == fm, "normal close returns to the file manager")
        end)

        local workers_ok, workers_err = pcall(function()
            T:run(function()
                while T:topWidget() and T:topWidget() ~= fm do UIManager:close(T:topWidget()) end
            end)
            T:wait() -- retain inputs while any queued launch drains
            T:run(function() BookInfoManager:terminateBackgroundJobs() end)
            T:waitUntil(function() return not BookInfoManager:isExtractingInBackground() end, 15, "cleanup worker reaping")
        end)
        -- Restore state even if a worker could not be stopped; retain its inputs then.
        BookInfoManager.extractInBackground = saved.extract
        ReadCollection.coll, ReadCollection.coll_settings = saved.coll, saved.settings
        manager.updated_collections = saved.dirty
        manager.booklist_menu, manager.match_table, manager.selected_files = saved.menu, saved.match, saved.selected
        local cleanup_ok, cleanup_err = pcall(function()
            if workers_ok then ffiUtil.purgeDir(base) end
        end)
        local errors = {}
        local function addError(label, failure)
            errors[#errors + 1] = label .. tostring(type(failure) == "table" and failure.msg or failure)
        end
        if not ok then addError("scenario: ", err) end
        if not workers_ok then addError("workers: ", workers_err) end
        if not cleanup_ok then addError("cleanup: ", cleanup_err) end
        if #errors > 0 then error(table.concat(errors, "\n")) end
    end,
}
