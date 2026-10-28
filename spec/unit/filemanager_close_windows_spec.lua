describe("FileManager window teardown", function()
    local FileManager, UIManager, InfoMessage, Screen, PluginLoader
    local saved_plugins, history_filter

    setup(function()
        require("commonrequire")
        PluginLoader = require("pluginloader")
        saved_plugins = { PluginLoader.enabled_plugins, PluginLoader.disabled_plugins, PluginLoader.loaded_plugins }
        disable_plugins()
        FileManager = require("apps/filemanager/filemanager")
        UIManager = require("ui/uimanager")
        InfoMessage = require("ui/widget/infomessage")
        Screen = require("device").screen
    end)

    teardown(function()
        PluginLoader.enabled_plugins, PluginLoader.disabled_plugins, PluginLoader.loaded_plugins = unpack(saved_plugins)
    end)

    before_each(function()
        history_filter = G_reader_settings:readSetting("history_filter")
    end)

    after_each(function()
        for i = #UIManager._window_stack, 1, -1 do
            UIManager:close(UIManager._window_stack[i].widget)
        end
        G_reader_settings:saveSetting("history_filter", history_filter)
    end)

    it("closes upper windows while their owning file manager is still alive", function()
        local fm = FileManager:new{
            dimen = Screen:getSize(),
            root_path = "spec/front/unit/data",
        }
        UIManager:show(fm)
        local alive_on_dismiss
        local overlay = InfoMessage:new{
            modal = false,
            text = "Synthetic FileManager dialog",
            dismiss_callback = function() alive_on_dismiss = FileManager.instance == fm end,
        }
        UIManager:show(overlay)
        assert.is_true(UIManager:isWidgetShown(overlay))
        assert.is_true(fm:onClose())
        assert.is_false(UIManager:isWidgetShown(overlay))
        assert.is_true(alive_on_dismiss)
        assert.is_nil(FileManager.instance)
    end)

    it("runs the history menu close callback before destroying its owner", function()
        local fm = FileManager:new{ dimen = Screen:getSize(), root_path = "spec/front/unit/data" }
        UIManager:show(fm)
        fm.history:onShowHist()
        fm.history.filter = "reading"
        local menu = fm.history.booklist_menu
        assert.is_true(UIManager:isWidgetShown(menu))
        fm:onClose()
        assert.is_false(UIManager:isWidgetShown(menu))
        assert.is_nil(fm.history.booklist_menu)
        assert.are.equal("reading", G_reader_settings:readSetting("history_filter"))
    end)
end)
