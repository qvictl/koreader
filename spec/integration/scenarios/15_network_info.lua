return {
    name = "Network interface information is displayed",
    timeout = 60,
    run = function(T)
        local Device = require("device")
        local Event = require("ui/event")
        local NetInfo = require("ffi/netinfo")
        local UIManager = require("ui/uimanager")
        local interfaces = T:run(function()
            local ni = NetInfo:new()
            local result = ni:retrieve()
            ni:free()
            return result
        end)
        T:eq(type(interfaces), "table", "native interface discovery succeeds")

        T:run(function()
            -- Exercise real interface discovery and the event/dialog path while
            -- keeping the optional gateway ping off the external network.
            local original_route = Device.getDefaultRoute
            Device.getDefaultRoute = function() return nil end
            local ok, err = xpcall(function()
                UIManager:broadcastEvent(Event:new("ShowNetworkInfo"))
            end, debug.traceback)
            Device.getDefaultRoute = original_route
            assert(ok, err)
        end)
        T:repaint()
        local dialog = T:topWidget()
        T:check(dialog and type(dialog.text) == "string" and dialog.text ~= "",
            "network information dialog is shown")
        T:check(dialog.dimen and dialog.dimen.w > 0 and dialog.dimen.h > 0,
            "network information dialog is painted")
        for _, iface in ipairs(interfaces) do
            T:check(dialog.text:find(iface.name, 1, true), "interface name is displayed")
            T:check(dialog.text:find(iface.mac, 1, true), "interface MAC address is displayed")
        end
        T:tapWidget(dialog)
        T:waitUntil(function() return T:topWidget() ~= dialog end, 5, "network dialog closes on tap")
        T:check(T:topWidget() == T:fileManager(), "closing network information returns to the browser")
    end,
}
