return {
    name = "FileManager dialogs and recreated input state",
    timeout = 60,
    run = function(T)
        local Device = require("device")
        local Input = require("device/input")
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        local FileManager = require("apps/filemanager/filemanager")
        local previous = T:fileManager()
        local dismissed_while_alive
        local overlay = InfoMessage:new{
            modal = false,
            text = "Synthetic browser-owned dialog",
            dismiss_callback = function() dismissed_while_alive = FileManager.instance == previous end,
        }
        T:run(function() UIManager:show(overlay) end)
        T:repaint()
        T:check(overlay.dimen and overlay.dimen.w > 0, "browser-owned dialog is painted")
        T:run(function() FileManager:showFiles(T:fixture("books")) end)
        T:waitUntil(function() return T:fileManager() and T:fileManager() ~= previous end, 5, "new file manager")
        T:check(not UIManager:isWidgetShown(overlay), "old browser-owned dialog is removed")
        T:check(dismissed_while_alive, "dialog closes before its owner is destroyed")
        T:check(T:topWidget() == T:fileManager(), "new file manager is the top window")

        T:run(function()
            local shortcuts = T:fileManager().folder_shortcuts
            local previous_shortcuts = shortcuts.folder_shortcuts
            shortcuts.folder_shortcuts = {}
            for i = 1, 80 do
                shortcuts.folder_shortcuts["/synthetic/source/sub" .. i] = { text = tostring(i) }
            end
            shortcuts:updateItemsByPath("/synthetic/source", "/synthetic/target")
            local all_moved = true
            for i = 1, 80 do
                local target = shortcuts.folder_shortcuts["/synthetic/target/sub" .. i]
                if not target or target.text ~= tostring(i)
                        or shortcuts.folder_shortcuts["/synthetic/source/sub" .. i] then
                    all_moved = false
                end
            end
            shortcuts.folder_shortcuts = previous_shortcuts
            T:check(all_moved, "renaming a folder moves every nested shortcut")

            local function newInput()
                return Input:new{ device = Device, input = Device.input.input, event_map = { [42] = "Shift" } }
            end
            local first, second = newInput(), newInput()
            first:handleKeyBoardEv{ code = 42, value = 1, fd = 0 }
            T:check(first.modifiers.Shift and not second.modifiers.Shift, "a held key does not cross input instances")
            first:handleKeyBoardEv{ code = 10040, value = 17, fd = 0 }
            T:eq(#first.fake_event_args.UsbDevicePlugIn, 1, "first input receives its USB event")
            T:eq(#second.fake_event_args.UsbDevicePlugIn, 0, "second input has no stale USB events")
            first.rotation_ignored_fds[-5432] = true
            T:eq(second.rotation_ignored_fds[-5432], nil, "rotation exceptions stay with their input")
            first.gesture_detector:newContact(0)
            first.gesture_detector.previous_tap[0] = { x = 10, y = 20 }
            T:eq(second.gesture_detector:getContact(0), nil, "contacts stay with their gesture detector")
            T:eq(second.gesture_detector.previous_tap[0], nil, "previous taps stay with their gesture detector")
            first.gesture_detector:dropContacts()
            first:handleKeyBoardEv{ code = 42, value = 0, fd = 0 }
        end)
        local reader = T:openBook(T:fixture("books/en.epub"))
        T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h / 2))
        T:waitUntil(function() return reader:getCurrentPage() == 2 end, 5, "real input still turns pages")
        T:closeBook()
    end,
}
