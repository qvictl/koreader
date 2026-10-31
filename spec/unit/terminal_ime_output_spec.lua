describe("Terminal output with keyboard input methods", function()
    local TermInputText
    local widget, unwrap, transmitted, saved_modules, saved_settings
    local stateful_modules = {
        "ui/data/keyboardlayouts/ko_KR_helper",
        "ui/data/keyboardlayouts/generic_ime",
    }

    setup(function()
        require("commonrequire")
        TermInputText = dofile("plugins/terminal.koplugin/terminputtext.lua")
    end)

    before_each(function()
        -- Both helpers keep shared composition state. Use private module
        -- instances, without disturbing a previously loaded keyboard.
        saved_modules = {}
        for _, name in ipairs(stateful_modules) do
            saved_modules[name] = package.loaded[name]
            package.loaded[name] = nil
        end
        saved_settings = G_reader_settings
        G_reader_settings = require("luasettings"):wrap{
            keyboard_layout = "en", keyboard_layout_default = "en",
        }
        transmitted = {}
        widget = TermInputText:new{
            text = "",
            width = require("device").screen:scaleBySize(600),
            height = require("device").screen:scaleBySize(300),
            for_measurement_only = true,
            strike_callback = function(chars)
                transmitted[#transmitted + 1] = chars
            end,
        }
    end)

    after_each(function()
        local unwrap_ok, unwrap_err = pcall(function()
            if unwrap then unwrap() end
        end)
        local free_ok, free_err = pcall(function()
            if widget then widget:free() end
        end)
        for _, name in ipairs(stateful_modules) do
            package.loaded[name] = saved_modules[name]
        end
        G_reader_settings = saved_settings
        widget, unwrap, transmitted = nil, nil, nil
        assert(unwrap_ok, unwrap_err)
        assert(free_ok, free_err)
    end)

    local function setLayout(lang)
        local layout = dofile("frontend/ui/data/keyboardlayouts/" .. lang .. "_keyboard.lua")
        if layout.wrapInputBox then unwrap = layout.wrapInputBox(widget) end
    end

    for _, lang in ipairs({"en", "zh_CN", "zh", "ja", "ko_KR", "vi"}) do
        it("renders literal output without retransmitting it with " .. lang, function()
            setLayout(lang)
            local add_chars = widget.addChars
            widget:interpretAnsiSeq("safe-output# 你好日本語한글 Tiếng Việt")
            assert.same({}, transmitted)
            assert.equals("safe-output# 你好日本語한글 Tiếng Việt", table.concat(widget.charlist))
            assert.equals(add_chars, widget.addChars) -- input method remains installed
        end)

        it("handles received backspace and cursor sequences with " .. lang, function()
            setLayout(lang)
            -- Seed the display directly so the control also reaches cursor
            -- handling on the old code, whose output path already misroutes text.
            TermInputText.addChars(widget, "abcdef", true)
            widget:interpretAnsiSeq("\008")
            assert.equals(6, widget.charpos)
            widget:interpretAnsiSeq("\027D")
            assert.equals(5, widget.charpos)
            widget:interpretAnsiSeq("\027C")
            assert.equals(6, widget.charpos)
            widget:interpretAnsiSeq("\027[2D")
            assert.equals(4, widget.charpos)
            widget:interpretAnsiSeq("\027[1C")
            assert.equals(5, widget.charpos)
            assert.same({}, transmitted)
            assert.equals("abcdef", table.concat(widget.charlist))
        end)

        it("still sends user input and cursor keys with " .. lang, function()
            setLayout(lang)
            TermInputText.addChars(widget, "abcdef", true)
            widget.charpos = 3
            widget:addChars("#")
            widget:leftChar()
            widget:rightChar()
            assert.same({"#", "\027[D", "\027[C"}, transmitted)
            assert.equals("abcdef", table.concat(widget.charlist))
        end)
    end

    it("does not start a synchronous receive/transmit echo loop", function()
        setLayout("zh_CN")
        local count = 0
        widget.strike_callback = function(chars)
            count = count + 1
            assert.is_true(count < 3, "terminal output was retransmitted recursively")
            widget:interpretAnsiSeq(chars)
        end
        widget:interpretAnsiSeq("synthetic-output# ")
        assert.equals(0, count)
        assert.equals("synthetic-output# ", table.concat(widget.charlist))
    end)

    it("preserves the intentional VT52 identification response", function()
        setLayout("zh_CN")
        widget:interpretAnsiSeq("\027Z")
        assert.same({"\027/K"}, transmitted)
    end)

    it("does not treat received Japanese text as a new composing key", function()
        setLayout("ja")
        widget:addChars("あ")
        assert.same({"あ"}, transmitted)
        local last_tap = widget._ja_last_tap_time
        assert.is_not_nil(last_tap)
        widget:interpretAnsiSeq("あ")
        assert.same({"あ"}, transmitted)
        assert.equals(last_tap, widget._ja_last_tap_time)
        assert.equals("あ", table.concat(widget.charlist))
    end)

    for _, movement in ipairs({
        { "backspace", "\008", 4 },
        { "VT52 left", "\027D", 4 },
        { "VT52 right", "\027C", 1 },
        { "CSI left", "\027[2D", 4 },
        { "CSI right", "\027[2C", 1 },
    }) do
        it("ends Japanese tap cycling after received " .. movement[1], function()
            setLayout("ja")
            TermInputText.addChars(widget, "あああ", true)
            widget.charpos = movement[3]
            widget:addChars("あ")
            assert.is_not_nil(widget._ja_last_tap_time)
            assert.same({"あ"}, transmitted)
            widget:interpretAnsiSeq(movement[2])
            assert.same({"あ"}, transmitted)
            widget:addChars("あ")
            assert.same({"あ", "あ"}, transmitted)
            assert.equals("あああ", table.concat(widget.charlist))
        end)
    end


    it("restores the external cursor callback when Japanese wrapping is removed", function()
        local moved = 0
        local previous = function() moved = moved + 1 end
        widget.onExternalCursorMove = previous
        setLayout("ja")
        TermInputText.addChars(widget, "あああ", true)
        widget:addChars("あ")
        widget:interpretAnsiSeq("\027D")
        assert.is_nil(widget._ja_last_tap_time)
        assert.equals(1, moved)
        assert.same({"あ"}, transmitted)
        unwrap()
        unwrap = nil
        assert.equals(previous, widget.onExternalCursorMove)
        widget:interpretAnsiSeq("\027D")
        assert.equals(2, moved)
    end)


    it("does not flush a Chinese candidate on received cursor movement", function()
        setLayout("zh_CN")
        widget:addChars("n")
        local first = transmitted[#transmitted]
        assert.is_not_nil(first)
        TermInputText.addChars(widget, first, true)
        local sent_count = #transmitted
        widget:interpretAnsiSeq("\027[D\027[C")
        assert.equals(sent_count, #transmitted)
        widget:rightChar() -- user next-candidate key, not terminal cursor input
        local second = transmitted[#transmitted]
        assert.is_not.equals(first, second)
        assert.is_not.equals("\027[C", second)
    end)

    it("renders CRLF output like the unwrapped terminal", function()
        local output = "first\r\nsecond\r\n第三行"
        widget:interpretAnsiSeq(output)
        local expected, pos = table.concat(widget.charlist), widget.charpos
        widget:initTextBox("")
        setLayout("zh_CN")
        widget:interpretAnsiSeq(output)
        assert.equals(expected, table.concat(widget.charlist))
        assert.equals(pos, widget.charpos)
        assert.same({}, transmitted)
    end)

    it("continues rendering after reverting and reinstalling the layout", function()
        setLayout("zh_CN")
        widget:interpretAnsiSeq("first ")
        unwrap()
        unwrap = nil
        widget:interpretAnsiSeq("second ")
        setLayout("ko_KR")
        widget:interpretAnsiSeq("third")
        assert.same({}, transmitted)
        assert.equals("first second third", table.concat(widget.charlist))
    end)
end)
