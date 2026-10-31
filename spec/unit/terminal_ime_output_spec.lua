describe("Terminal output with keyboard input methods", function()
    local TermInputText
    local widget, unwrap, transmitted, saved_modules, saved_settings, saved_now
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
        saved_now = require("ui/time").now
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
        assert.equals(saved_now, require("ui/time").now)
        widget, unwrap, transmitted = nil, nil, nil
        assert(unwrap_ok, unwrap_err)
        assert(free_ok, free_err)
    end)

    local function setLayout(lang)
        local path = "frontend/ui/data/keyboardlayouts/" .. lang .. "_keyboard.lua"
        local layout
        if lang == "ja" then
            -- Only this private layout sees a fixed clock; UIManager time is untouched.
            local real_time = require("ui/time")
            local now = real_time.s(100)
            local clock = setmetatable({
                now = function() return now end,
                since = function(start) return now - start end,
            }, { __index = real_time })
            local chunk = assert(loadfile(path))
            setfenv(chunk, setmetatable({ require = function(name)
                if name == "ui/time" then return clock end
                return require(name)
            end }, { __index = _G }))
            layout = chunk()
        else
            layout = dofile(path)
        end
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
            assert.is_nil(widget._ja_last_tap_time)
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
        widget:interpretAnsiSeq("\027[2D")
        assert.is_nil(widget._ja_last_tap_time)
        assert.equals(1, moved)
        assert.same({"あ"}, transmitted)
        unwrap()
        unwrap = nil
        assert.equals(previous, widget.onExternalCursorMove)
        widget:interpretAnsiSeq("\027[2D")
        assert.equals(2, moved)
    end)


    local function echoPending(index)
        while index <= #transmitted do
            assert.is_true(index < 80, "bounded synthetic echo")
            widget:interpretAnsiSeq(transmitted[index])
            index = index + 1
        end
        return index
    end

    for _, item in ipairs({
        { "ja", {"あ", "あ", "あ"}, "う" },
        { "ko_KR", {"ㄱ", "ㅏ", "ㄴ"}, "간" },
        { "vi", {"a", "w", "s"}, "ắ" },
    }) do
        it("preserves normal " .. item[1] .. " composition across its own BS echo", function()
            setLayout(item[1])
            local index = 1
            for _, key in ipairs(item[2]) do
                widget:addChars(key)
                index = echoPending(index)
            end
            assert.equals(item[3], table.concat(widget.charlist))
        end)
    end

    for _, item in ipairs({
        { "ko_KR", {"ㄱ"}, "ㅏ" },
        { "vi", {"a", "w"}, "s" },
        { "zh_CN", {"n"}, "i" },
        { "zh", {"㇐"}, "㇑" },
    }) do
        for _, movement in ipairs({ "\027D", "\027C", "\027[1D", "\027[1C" }) do
            it("starts new " .. item[1] .. " input after explicit movement " .. movement, function()
                G_reader_settings:saveSetting("keyboard_chinese_pinyin_settings", {show_candi = false})
                G_reader_settings:saveSetting("keyboard_chinese_stroke_show_candidates", false)
                setLayout(item[1])
                TermInputText.addChars(widget, "PREFIX", true)
                local index = 1
                for _, key in ipairs(item[2]) do
                    widget:addChars(key)
                    index = echoPending(index)
                end
                -- Supply trailing cells so right movement has a valid destination.
                TermInputText.addChars(widget, "__", true)
                widget.charpos = #widget.charlist - 1
                local old_count = #transmitted
                widget:interpretAnsiSeq(movement)
                assert.equals(old_count, #transmitted)
                widget:addChars(item[3])
                assert.is_true(#transmitted > old_count)
                for i = old_count + 1, #transmitted do
                    assert.is_nil(transmitted[i]:find("\008", 1, true))
                end
                echoPending(index)
                assert.equals("PREFIX", table.concat(widget.charlist):sub(1, 6))
            end)
        end
        it("restores a prior external-move callback after " .. item[1] .. " unwrapping", function()
            local count = 0
            local previous = function() count = count + 1 end
            widget.onExternalCursorMove = previous
            setLayout(item[1])
            -- Empty display: even a boundary no-op notifies once per command.
            widget:interpretAnsiSeq("\027[2D")
            assert.equals(1, count)
            widget:interpretAnsiSeq("\027[2C")
            assert.equals(2, count)
            unwrap()
            unwrap = nil
            assert.equals(previous, widget.onExternalCursorMove)
            widget:interpretAnsiSeq("\027[2D")
            assert.equals(3, count)
        end)
    end

    it("preserves Chinese candidate cycling while its echoed anchor is unchanged", function()
        G_reader_settings:saveSetting("keyboard_chinese_pinyin_settings", {show_candi = false})
        setLayout("zh_CN")
        TermInputText.addChars(widget, "PREFIX", true)
        widget:addChars("n")
        local index = echoPending(1)
        local old_text, old_pos = table.concat(widget.charlist), widget.charpos
        widget:interpretAnsiSeq("")
        assert.equals(old_pos, widget.charpos)
        widget:rightChar() -- User candidate cycling at the same echoed anchor.
        echoPending(index)
        assert.equals(#widget.charlist + 1, widget.charpos)
        assert.equals("PREFIX", table.concat(widget.charlist):sub(1, 6))
        assert.is_not.equals(old_text, table.concat(widget.charlist))
    end)

    for _, item in ipairs({
        {"zh_CN", {"n", "i"}, "i"},
        {"zh", {"㇐", "㇑"}, "㇒"},
    }) do
        it("does not erase displayed " .. item[1] .. " candidate hints on external movement", function()
            G_reader_settings:saveSetting("keyboard_chinese_pinyin_settings", {show_candi = true})
            G_reader_settings:saveSetting("keyboard_chinese_stroke_show_candidates", true)
            setLayout(item[1])
            TermInputText.addChars(widget, "PREFIX", true)
            local index = 1
            for _, key in ipairs(item[2]) do
                widget:addChars(key)
                index = echoPending(index)
            end
            local old_text, old_count = table.concat(widget.charlist), #transmitted
            assert.is_not_nil(old_text:find("[", 1, true))
            widget:interpretAnsiSeq("\027[D")
            assert.equals(old_count, #transmitted)
            assert.equals(old_text, table.concat(widget.charlist))
            widget:addChars(item[3])
            for i = old_count + 1, #transmitted do
                assert.is_nil(transmitted[i]:find("\008", 1, true))
            end
            echoPending(index)
            assert.equals("PREFIX", table.concat(widget.charlist):sub(1, 6))
        end)
    end

    for _, lang in ipairs({"ja", "ko_KR", "vi", "zh_CN", "zh"}) do
        it("removes its private external-move hook when " .. lang .. " is unwrapped", function()
            assert.is_nil(rawget(widget, "onExternalCursorMove"))
            setLayout(lang)
            assert.is_not_nil(rawget(widget, "onExternalCursorMove"))
            unwrap()
            unwrap = nil
            assert.is_nil(rawget(widget, "onExternalCursorMove"))
            widget:interpretAnsiSeq("\027D")
            assert.same({}, transmitted)
        end)
    end

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
