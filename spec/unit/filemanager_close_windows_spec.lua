describe("FileManager window teardown", function()
    local FileManager, UIManager, InfoMessage, Screen

    setup(function()
        require("commonrequire")
        disable_plugins()
        FileManager = require("apps/filemanager/filemanager")
        UIManager = require("ui/uimanager")
        InfoMessage = require("ui/widget/infomessage")
        Screen = require("device").screen
    end)

    after_each(function()
        for i = #UIManager._window_stack, 1, -1 do
            UIManager:close(UIManager._window_stack[i].widget)
        end
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
end)
