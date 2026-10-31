describe("Cover menu deferred extraction lifecycle", function()
    local BookInfoManager, CoverMenu, Menu, UIManager
    local saved_path, saved_cover, saved_bookinfo, saved
    local queued, launches, notices, stops, closes, cleanups, launch_ok

    setup(function()
        require("commonrequire")
        saved_path = package.path
        saved_cover, saved_bookinfo = package.loaded.covermenu, package.loaded.bookinfomanager
        package.path = "plugins/coverbrowser.koplugin/?.lua;" .. package.path
        BookInfoManager = require("bookinfomanager")
        CoverMenu = require("covermenu")
        Menu = require("ui/widget/menu")
        UIManager = require("ui/uimanager")
    end)

    teardown(function()
        package.path = saved_path
        package.loaded.covermenu, package.loaded.bookinfomanager = saved_cover, saved_bookinfo
    end)

    local function replace(object, key, value)
        saved[#saved + 1] = { object, key, object[key] }
        object[key] = value
    end

    before_each(function()
        saved, queued, launches = {}, {}, {}
        notices, stops, closes, cleanups, launch_ok = 0, 0, 0, 0, true
        replace(UIManager, "nextTick", function(_, action) queued[#queued + 1] = action end)
        replace(UIManager, "scheduleIn", function() end)
        replace(UIManager, "unschedule", function() end)
        replace(UIManager, "setDirty", function() end)
        replace(UIManager, "show", function() notices = notices + 1 end)
        replace(Menu, "mergeTitleBarIntoLayout", function() end)
        replace(Menu, "onCloseWidget", function() end)
        replace(BookInfoManager, "extractInBackground", function(_, files)
            launches[#launches + 1] = files
            return launch_ok
        end)
        replace(BookInfoManager, "terminateBackgroundJobs", function() stops = stops + 1 end)
        replace(BookInfoManager, "closeDbConnection", function() closes = closes + 1 end)
        replace(BookInfoManager, "cleanUp", function() cleanups = cleanups + 1 end)
    end)

    after_each(function()
        for i = #saved, 1, -1 do
            local entry = saved[i]
            entry[1][entry[2]] = entry[3]
        end
    end)

    local function menu()
        local reset = { resetLayout = function() end }
        return setmetatable({
            item_group = { clear = function() end, free = function() end },
            page_info = reset, return_button = reset, content_group = reset,
            show_parent = {},
            updatePageInfo = function() end,
            _updateItemsBuildUI = function(self)
                self.items_to_update = {{ filepath = "synthetic.epub", cover_specs = { max_w = 60 } }}
            end,
        }, { __index = CoverMenu })
    end

    it("starts the queued extraction while its menu is still open", function()
        local widget = menu()
        widget:updateItems(nil, true)
        assert.equals(1, #queued)
        assert.equals(0, #launches)
        queued[1]()
        assert.same({{ filepath = "synthetic.epub", cover_specs = { max_w = 60 } }}, launches[1])
    end)

    it("does not start a queued extraction after the menu closes", function()
        local widget = menu()
        widget:updateItems(nil, true)
        widget:onCloseWidget()
        assert.is_nil(widget.items_update_action)
        queued[1]()
        assert.equals(0, #launches)
        assert.equals(1, stops)
        assert.equals(1, closes)
        assert.equals(1, cleanups)
    end)

    it("does not show a late launch-failure dialog for a closed menu", function()
        local widget = menu()
        widget:updateItems(nil, true)
        widget:onCloseWidget()
        launch_ok = false
        queued[1]()
        assert.equals(0, notices)
        assert.equals(0, #launches)
    end)

    it("still stops extraction when closing after launch", function()
        local widget = menu()
        widget:updateItems(nil, true)
        queued[1]()
        widget:onCloseWidget()
        assert.equals(1, #launches)
        assert.equals(1, stops)
    end)

    it("keeps repeated close idempotent before the queued launch", function()
        local widget = menu()
        widget:updateItems(nil, true)
        widget:onCloseWidget()
        widget:onCloseWidget()
        queued[1]()
        assert.equals(0, #launches)
        assert.equals(1, stops)
        assert.equals(1, closes)
        assert.equals(1, cleanups)
    end)

    it("still reports a failed launch while the menu is open", function()
        local widget = menu()
        widget:updateItems(nil, true)
        launch_ok = false
        queued[1]()
        assert.equals(1, #launches)
        assert.equals(1, notices)
        assert.is_nil(widget.items_update_action)
    end)
end)
