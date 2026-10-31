-- Real InputDialog, terminal text parser and VirtualKeyboard. No shell or PTY:
-- received text is synthetic and every transmitted byte is only captured.
return {
    name = "Terminal output does not become IME keyboard input",
    timeout = 45,
    settings = { language = "en", keyboard_layout = "en", keyboard_layout_default = "en",
        virtual_keyboard_enabled = true },
    run = function(T)
        local UIManager = require("ui/uimanager")
        local InputDialog = require("ui/widget/inputdialog")
        local TermInputText = dofile("plugins/terminal.koplugin/terminputtext.lua")
        local modules = { "ui/data/keyboardlayouts/generic_ime", "ui/data/keyboardlayouts/ko_KR_helper" }
        local languages = { "en", "zh_CN", "zh", "ja", "ko_KR", "vi" }
        for _, lang in ipairs(languages) do
            modules[#modules + 1] = "ui/data/keyboardlayouts/" .. lang .. "_keyboard"
        end
        local saved_modules, saved_settings = {}, {}
        for _, name in ipairs(modules) do saved_modules[name] = package.loaded[name] end
        for _, key in ipairs({"keyboard_layout", "keyboard_layout_default", "keyboard_remember_layout"}) do
            saved_settings[key] = G_reader_settings:readSetting(key)
        end
        local dialog, sent
        local children = {}
        for _, pid in ipairs(T:children()) do children[pid] = true end
        local function openDialog(lang)
            T:run(function()
                G_reader_settings:saveSetting("keyboard_layout", lang)
                G_reader_settings:saveSetting("keyboard_layout_default", lang)
                G_reader_settings:saveSetting("keyboard_remember_layout", true)
                sent = {}
                dialog = InputDialog:new{
                    title = "Synthetic terminal output (no shell)", input = "",
                    fullscreen = true, allow_newline = false,
                    inputtext_class = TermInputText,
                    strike_callback = function(chars) sent[#sent + 1] = chars end,
                    buttons = {{ { text = "Close fixture", callback = function() UIManager:close(dialog) end } }},
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end)
            T:repaint()
            T:check(dialog._input_widget:isKeyboardVisible(), lang .. " virtual keyboard is shown")
        end
        local function closeDialog()
            local button = T:findWidget(dialog, function(w)
                return w.text == "Close fixture" and w.onTapSelectButton
            end)
            T:tapWidget(button, "close terminal fixture")
            dialog = nil
            T:check(T:topWidget() == T:fileManager(), "closing terminal returns to usable FileManager")
        end
        local ok, err = pcall(function()
            for _, name in ipairs(modules) do package.loaded[name] = nil end
            for _, lang in ipairs(languages) do
                openDialog(lang)
                local text = "safe-output# 你好日本語한글 Tiếng Việt"
                T:run(function() dialog._input_widget:interpretAnsiSeq(text) end)
                T:repaint()
                T:eq(#sent, 0, lang .. " output never reaches transmit callback")
                T:eq(dialog:getInputText(), text, lang .. " displays exact received text")
                local before = dialog._input_widget.charpos
                T:run(function()
                    for _, sequence in ipairs({ "\008", "\027D", "\027C", "\027[1D" }) do
                        dialog._input_widget:interpretAnsiSeq(sequence)
                    end
                end)
                T:eq(#sent, 0, lang .. " received cursor operations do not transmit")
                T:eq(dialog._input_widget.charpos, before - 2, lang .. " received cursor operations move locally")
                closeDialog()
            end

            openDialog("zh_CN")
            local key = T:findWidget(dialog._input_widget.keyboard, function(w)
                return w.key == "n" and w.callback
            end)
            T:tapWidget(key, "real pinyin keyboard n key")
            T:check(#sent > 0, "user keyboard input still reaches captured transmit callback")
            local count = #sent
            T:run(function() dialog._input_widget:interpretAnsiSeq("received reply# ") end)
            T:eq(#sent, count, "a reply after user input is not sent back")
            T:run(function() dialog._input_widget.keyboard:setKeyboardLayout("ko_KR") end)
            T:repaint()
            T:run(function() dialog._input_widget:interpretAnsiSeq("한글") end)
            T:eq(#sent, count, "live layout replacement does not restore the echo loop")
            T:check(dialog:getInputText():find("한글", 1, true) ~= nil, "replacement keyboard renders received Hangul")
            closeDialog()
            openDialog("ja")
            T:run(function() dialog._input_widget:interpretAnsiSeq("reopened 日本語") end)
            T:eq(#sent, 0, "reopened terminal retains output-only semantics")
            T:eq(dialog:getInputText(), "reopened 日本語", "reopened terminal displays new output")
            closeDialog()
            local no_new_children = true
            for _, pid in ipairs(T:children()) do
                if not children[pid] then no_new_children = false end
            end
            T:check(no_new_children, "no new live child remains after the widget-only fixture")
        end)
        local cleanup_ok, cleanup_err = pcall(function()
            if dialog then T:run(function() UIManager:close(dialog) end) end
        end)
        for _, name in ipairs(modules) do package.loaded[name] = saved_modules[name] end
        for key, _ in pairs({ keyboard_layout = true, keyboard_layout_default = true, keyboard_remember_layout = true }) do
            G_reader_settings:saveSetting(key, saved_settings[key])
        end
        if not ok or not cleanup_ok then
            local function message(e) return tostring(type(e) == "table" and e.msg or e) end
            error((not ok and message(err) or "") .. (not cleanup_ok and " cleanup: " .. message(cleanup_err) or ""), 0)
        end
        T:check(T:topWidget() == T:fileManager(), "final view is the FileManager with all dialogs dismissed")
    end,
}
