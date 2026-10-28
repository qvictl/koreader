describe("DictQuickLookup visible geometry", function()
    local DictQuickLookup, Geom

    setup(function()
        require("commonrequire")
        DictQuickLookup = require("ui/widget/dictquicklookup")
        Geom = require("ui/geometry")
    end)

    it("reports both axes for every vertical alignment", function()
        local window = setmetatable({
            region = Geom:new{
                x = 47,
                y = 83,
                w = 600,
                h = 1000,
            },
            dict_frame = { getSize = function() return { w = 240, h = 360 } end },
        }, { __index = DictQuickLookup })
        for align, expected_y in pairs{ top = 83, bottom = 723, center = 403 } do
            window.align = align
            local area = window:getInitialVisibleArea()
            assert.are.same({ x = 227, y = expected_y, w = 240, h = 360 },
                { x = area.x, y = area.y, w = area.w, h = area.h })
        end
    end)
end)
