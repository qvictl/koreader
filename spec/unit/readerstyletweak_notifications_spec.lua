describe("Style tweak notification preferences", function()
    local ReaderStyleTweak, Notification, UIManager, Input
    local style, shown, applied, original_show, saved
    local tweak_id = "private_notification_tweak"
    local methods = {
        { name = "individual tweak", call = function(r, silent) return r:onToggleStyleTweak(tweak_id, nil, silent) end,
            changed = function(r) return r.doc_tweaks[tweak_id] == true end },
        { name = "all tweaks", call = function(r, silent) return r:onToggleStyleTweaks(silent) end,
            changed = function(r) return r.enabled == false end },
        { name = "book tweak", call = function(r, silent) return r:onToggleBookTweak(nil, silent) end,
            changed = function(r) return r.book_style_tweak_enabled == true end },
    }

    setup(function()
        require("commonrequire")
        ReaderStyleTweak = require("apps/reader/modules/readerstyletweak")
        Notification = require("ui/widget/notification")
        UIManager = require("ui/uimanager")
        Input = require("device").input
    end)

    before_each(function()
        saved = {
            mask = G_reader_settings:readSetting("notification_sources_to_show_mask"),
            source = rawget(Notification, "notify_source"),
            shown_list = Notification._shown_list, past_messages = Notification._past_messages,
            double_tap = rawget(Input, "disable_double_tap"),
            concurrent = rawget(Input, "allow_concurrent_taps"),
            tap_interval = rawget(Input, "tap_interval_override"),
        }
        Notification._shown_list, Notification._past_messages = {}, {}
        Notification:setNotifySource(Notification.SOURCE_DISPATCHER)
        shown, applied = {}, 0
        original_show = UIManager.show
        UIManager.show = function(manager, widget, ...)
            shown[#shown + 1] = widget
            return original_show(manager, widget, ...)
        end
        style = setmetatable({
            enabled = true, global_tweaks = {}, doc_tweaks = {},
            tweaks_by_id = { [tweak_id] = { id = tweak_id, priority = 0, css = "p { margin: 0; }" } },
            tweaks_in_dispatcher = { [tweak_id] = "Private notification tweak" },
            book_style_tweak = "p { text-indent: 0; }", book_style_tweak_enabled = false,
            ui = { handleEvent = function(_, event)
                assert.are.equal("onApplyStyleSheet", event.handler)
                applied = applied + 1
            end },
        }, { __index = ReaderStyleTweak })
    end)

    after_each(function()
        UIManager.show = original_show
        for _, widget in ipairs(shown) do
            if UIManager:isWidgetShown(widget) then UIManager:close(widget) end
        end
        Notification._shown_list, Notification._past_messages = saved.shown_list, saved.past_messages
        Notification.notify_source = saved.source
        G_reader_settings:saveSetting("notification_sources_to_show_mask", saved.mask)
        Input.disable_double_tap = saved.double_tap
        Input.allow_concurrent_taps = saved.concurrent
        Input.tap_interval_override = saved.tap_interval
    end)

    for _, method in ipairs(methods) do
        for _, case in ipairs({
            { name = "disabled mask", mask = 0, source = 32, count = 0 },
            { name = "other-only mask", mask = 64, source = 32, count = 0 },
            { name = "dispatcher mask", mask = 32, source = 32, count = 1 },
            { name = "default mask", source = 32, count = 1 },
            { name = "other source enabled", mask = 64, source = 64, count = 1 },
            { name = "other source excluded", mask = 32, source = 64, count = 0 },
        }) do
            it("respects " .. case.name .. " for " .. method.name, function()
                G_reader_settings:saveSetting("notification_sources_to_show_mask", case.mask)
                Notification:setNotifySource(case.source)
                method.call(style)
                assert.is_true(method.changed(style))
                assert.are.equal(1, applied)
                assert.are.equal(case.count, #shown)
                assert.are.equal(case.count, #Notification:getPastMessages())
                assert.are.equal(case.source, Notification:getNotifySource())
                if shown[1] then
                    assert.are.equal(Notification, getmetatable(shown[1]))
                    assert.is_true(UIManager:isWidgetShown(shown[1]))
                end
            end)
        end

        it("keeps explicit menu suppression for " .. method.name, function()
            G_reader_settings:saveSetting("notification_sources_to_show_mask", Notification.SOURCE_ALL)
            method.call(style, true)
            assert.is_true(method.changed(style))
            assert.are.equal(1, applied)
            assert.are.equal(0, #shown)
        end)

        it("keeps repeated toggling and feedback for " .. method.name, function()
            G_reader_settings:saveSetting("notification_sources_to_show_mask", Notification.SOURCE_DISPATCHER)
            method.call(style)
            method.call(style)
            assert.is_false(method.changed(style))
            assert.are.equal(2, applied)
            assert.are.equal(2, #shown)
            assert.are_not.equal(shown[1].text, shown[2].text)
        end)
    end

    it("keeps explicit set operations idempotent", function()
        G_reader_settings:saveSetting("notification_sources_to_show_mask", Notification.SOURCE_DISPATCHER)
        style:onToggleStyleTweak({ tweak_id, true })
        style:onToggleStyleTweak({ tweak_id, true })
        assert.is_true(style.doc_tweaks[tweak_id])
        assert.are.equal(1, applied)
        assert.are.equal(1, #shown)
        style:onToggleStyleTweak({ tweak_id, false })
        assert.is_nil(style.doc_tweaks[tweak_id])
        assert.are.equal(2, applied)
        assert.are.equal(2, #shown)
    end)

    it("preserves document overrides of a globally enabled tweak", function()
        G_reader_settings:saveSetting("notification_sources_to_show_mask", 0)
        style.global_tweaks[tweak_id] = true
        style:onToggleStyleTweak(tweak_id)
        assert.is_false(style.doc_tweaks[tweak_id])
        assert.is_true(style.global_tweaks[tweak_id])
        assert.are.equal(1, applied)
        assert.are.equal(0, #shown)
    end)

    it("does not notify or apply unknown tweaks", function()
        assert.is_true(style:onToggleStyleTweak("unknown_notification_tweak"))
        assert.are.equal(0, applied)
        assert.are.equal(0, #shown)
    end)

    it("still opens the editor when no book-specific tweak exists", function()
        local edited, menu = 0, {}
        style.book_style_tweak = nil
        style.onEditBookTweak = function(_, received)
            assert.are.equal(menu, received)
            edited = edited + 1
        end
        style:onToggleBookTweak(menu)
        assert.are.equal(1, edited)
        assert.are.equal(0, applied)
        assert.are.equal(0, #shown)
    end)
end)
