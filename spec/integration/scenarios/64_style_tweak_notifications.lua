-- Real profile execution, notification preferences, native EPUB and painted toasts.
return {
    name = "Style tweak actions respect notification preferences",
    timeout = 90,
    settings = { language = "en", style_tweaks = {}, notification_sources_to_show_mask = 0,
        cover_image_enabled = false, cover_image_fallback = false },
    run = function(T)
        local Dispatcher = require("dispatcher")
        local Notification = require("ui/widget/notification")
        local NotificationMenu = require("ui/elements/screen_notification_menu_table")
        local TouchMenu = require("ui/widget/touchmenu")
        local UIManager = require("ui/uimanager")
        local util = require("util")
        local ui, plugin, style, menu, owns_actions
        local shown, names, saved = {}, {}, {}
        local keys = { "notification_sources_to_show_mask", "profiles_autoexec", "style_tweaks_in_dispatcher" }
        for _, key in ipairs(keys) do saved[key] = G_reader_settings:readSetting(key) end
        local original_show = UIManager.show
        UIManager.show = function(manager, widget, ...)
            if getmetatable(widget) == Notification then shown[#shown + 1] = widget end
            return original_show(manager, widget, ...)
        end
        local function clearNotices()
            T:run(function()
                for _, widget in ipairs(shown) do
                    if UIManager:isWidgetShown(widget) then UIManager:close(widget) end
                end
            end)
            shown = {}
        end
        local function openBook()
            ui = T:openBook(T:fixture("books/en.epub"))
            plugin, style = assert(ui.profiles), ui.styletweak
        end
        local function tapItem(text)
            T:repaint()
            local item = T:findWidget(menu, function(w) return w.item and w.item.text == text end)
            T:check(item, "real menu item exists: " .. text)
            T:tapWidget(item, text)
        end
        local function openProfile(name)
            clearNotices()
            local entry
            for _, item in ipairs(plugin:getSubMenuItems()) do
                if item.name == name then entry = item break end
            end
            T:check(entry, "private profile appears in the real profile menu")
            T:run(function()
                menu = TouchMenu:new{ width = T.screen_w, tab_item_table = {
                    { icon = "appbar.tools", unpack(entry.sub_item_table) },
                } }
                UIManager:show(menu)
            end)
        end
        local function executeProfile(name, expected)
            openProfile(name)
            tapItem("Execute")
            T:check(not UIManager:isWidgetShown(menu), "profile menu closes on execute")
            menu = nil
            T:repaint()
            T:eq(#shown, expected, "profile action emits only permitted notifications")
            for _, widget in ipairs(shown) do
                T:check(UIManager:isWidgetShown(widget), "permitted notification is shown")
                T:check(widget.frame.dimen and widget.frame.dimen.w > 0, "permitted toast has been painted")
            end
        end
        local function toggleNotifications()
            clearNotices()
            T:run(function()
                menu = TouchMenu:new{ width = T.screen_w, tab_item_table = {
                    { icon = "appbar.settings", unpack(NotificationMenu.sub_item_table) },
                } }
                UIManager:show(menu)
            end)
            tapItem("From gestures and profiles")
            T:run(function() UIManager:close(menu) end)
            menu = nil
        end
        local ok, err = pcall(function()
            openBook()
            G_reader_settings:saveSetting("notification_sources_to_show_mask", 0)
            T:check(style.tweaks_in_dispatcher.margin_body_0 == nil, "private tweak title is absent")
            T:eq(Dispatcher:getNameFromItem("style_tweak_margin_body_0"), "Unknown item", "toggle action is absent")
            T:eq(Dispatcher:getNameFromItem("style_tweak_set_margin_body_0"), "Unknown item", "set action is absent")
            style.tweaks_in_dispatcher = util.tableDeepCopy(style.tweaks_in_dispatcher)
            style.tweaks_in_dispatcher.margin_body_0 = "Private margin notification tweak"
            owns_actions = true
            style:onDispatcherRegisterActions()
            style.book_style_tweak = "p { text-indent: 0; }"
            style.book_style_tweak_enabled = false
            local actions = { "toggle_style_tweaks", "style_tweak_margin_body_0", "toggle_book_tweak" }
            for i, action in ipairs(actions) do
                local name = "Notification probe " .. i
                T:check(plugin.data[name] == nil, "owned profile name is absent")
                names[#names + 1] = name
                plugin.data[name] = { settings = { name = name }, [action] = true }
                executeProfile(name, 0)
            end
            T:check(not style.enabled and style.doc_tweaks.margin_body_0 and style.book_style_tweak_enabled,
                "all three masked actions still update their settings")
            toggleNotifications()
            T:eq(G_reader_settings:readSetting("notification_sources_to_show_mask"), Notification.SOURCE_DISPATCHER,
                "real preferences enable gesture/profile notifications")
            for _, name in ipairs(names) do executeProfile(name, 1) end
            T:check(style.enabled and not style.doc_tweaks.margin_body_0 and not style.book_style_tweak_enabled,
                "repeated actions restore their original state")

            local batch = "Notification probe batch"
            T:check(plugin.data[batch] == nil, "owned batch profile name is absent")
            names[#names + 1] = batch
            plugin.data[batch] = { settings = { name = batch, order = actions } }
            for _, action in ipairs(actions) do plugin.data[batch][action] = true end
            executeProfile(batch, 3)
            T:check(not plugin.data[batch].settings.notify, "profile flag only controls its execution message")
            openProfile(batch)
            tapItem("Show notification on executing")
            T:check(plugin.data[batch].settings.notify, "real profile checkbox enables execution message")
            T:run(function() UIManager:close(menu) end)
            menu = nil
            executeProfile(batch, 4)
            T:check(shown[1].text:find("Executing profile:", 1, true), "profile execution message is retained")
            toggleNotifications()
            T:eq(G_reader_settings:readSetting("notification_sources_to_show_mask"), 0, "real preferences disable notifications again")
            executeProfile(batch, 0)

            -- The actual ReaderReady event runs the persisted profile on reopen.
            G_reader_settings:saveSetting("profiles_autoexec", { ReaderReady = { [batch] = true } })
            local previous = style.enabled
            T:closeBook()
            openBook()
            T:waitUntil(function() return style.enabled ~= previous end, 5, "automatic profile applies after opening")
            T:eq(#shown, 0, "automatic profile respects disabled notifications")
            T:check(style.css_text ~= nil, "automatic action re-enables native style application")
            toggleNotifications()
            previous = style.enabled
            T:closeBook()
            openBook()
            T:waitUntil(function() return style.enabled ~= previous end, 5, "automatic profile runs on another reopen")
            T:repaint()
            T:eq(#shown, 4, "enabled automatic profile keeps execution and action messages")
            clearNotices()
            G_reader_settings:saveSetting("profiles_autoexec", {})
            T:tap(math.floor(T.screen_w * 0.9), math.floor(T.screen_h / 2))
            T:waitUntil(function() return ui:getCurrentPage() == 2 end, 3, "page turn after notifications close")
        end)
        local errors = {}
        if not ok then errors[#errors + 1] = tostring(type(err) == "table" and err.msg or err) end
        local function cleanup(fn)
            local cleaned, failure = pcall(fn)
            if not cleaned then errors[#errors + 1] = tostring(failure) end
        end
        cleanup(clearNotices)
        cleanup(function()
            if menu and UIManager:isWidgetShown(menu) then T:run(function() UIManager:close(menu) end) end
        end)
        if plugin then
            for _, name in ipairs(names) do plugin.data[name] = nil end
            plugin.updated = true
        end
        cleanup(function() T:closeBook() end)
        UIManager.show = original_show
        if owns_actions then
            Dispatcher:removeAction("style_tweak_margin_body_0")
            Dispatcher:removeAction("style_tweak_set_margin_body_0")
        end
        for _, key in ipairs(keys) do G_reader_settings:saveSetting(key, saved[key]) end
        if #errors > 0 then error(table.concat(errors, "\n")) end
        T:check(T:topWidget() == T:fileManager(), "reader and notifications close back to FileManager")
    end,
}
