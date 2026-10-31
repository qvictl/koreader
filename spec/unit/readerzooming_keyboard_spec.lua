describe("ReaderZooming keyboard zoom", function()
    local DataStorage, DocumentRegistry, Event, ReaderUI, Screen, UIManager, lfs
    local ui, root, serial, owns_root, PluginLoader, saved_plugins
    local files = {}

    setup(function()
        require("commonrequire")
        PluginLoader = require("pluginloader")
        saved_plugins = { PluginLoader.enabled_plugins, PluginLoader.disabled_plugins, PluginLoader.loaded_plugins }
        disable_plugins()
        DataStorage = require("datastorage")
        DocumentRegistry = require("document/documentregistry")
        Event = require("ui/event")
        ReaderUI = require("apps/reader/readerui")
        Screen = require("device").screen
        UIManager = require("ui/uimanager")
        lfs = require("libs/libkoreader-lfs")
        root = DataStorage:getDataDir() .. "/keyboard-zoom-spec"
        assert.is_nil(lfs.attributes(root))
        assert.is_true(require("util").makePath(root))
        owns_root = true
        serial = 0
    end)

    teardown(function()
        local ok, err = pcall(function()
            if owns_root and not ui then
                for _, file in ipairs(files) do
                    require("docsettings"):open(file):purge()
                    assert(os.remove(file))
                end
                assert(lfs.rmdir(root))
            end
        end)
        if saved_plugins then
            PluginLoader.enabled_plugins, PluginLoader.disabled_plugins, PluginLoader.loaded_plugins = unpack(saved_plugins, 1, 3)
        end
        if not ok then error(err) end
    end)

    before_each(function()
        serial = serial + 1
        local file = root .. "/" .. serial .. ".pdf"
        files[#files + 1] = file
        local stream = "BT /F1 18 Tf 60 700 Td (Synthetic keyboard zoom test) Tj ET\n"
        local objects = {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [5 0 R 6 0 R 7 0 R] /Count 3 >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length " .. #stream .. " >>\nstream\n" .. stream .. "endstream",
        }
        for i = 5, 7 do
            objects[i] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
                .. " /Resources << /Font << /F1 3 0 R >> >> /Contents 4 0 R >>"
        end
        local bytes, offsets = "%PDF-1.4\n", {}
        for i, object in ipairs(objects) do
            offsets[i] = #bytes
            bytes = bytes .. i .. " 0 obj\n" .. object .. "\nendobj\n"
        end
        local start = #bytes
        bytes = bytes .. "xref\n0 8\n0000000000 65535 f \n"
        for _, offset in ipairs(offsets) do bytes = bytes .. string.format("%010d 00000 n \n", offset) end
        bytes = bytes .. "trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n" .. start .. "\n%%EOF\n"
        local f = assert(io.open(file, "wb"))
        assert(f:write(bytes))
        assert(f:close())
        ui = ReaderUI:new{ dimen = Screen:getSize(), document = DocumentRegistry:openDocument(file) }
        UIManager:show(ui)
        ui:handleEvent(Event:new("SetScrollMode", false))
        ui.zooming:setZoomMode("page", true)
        ui.paging:onGotoPage(2)
    end)

    after_each(function()
        if ui then
            ui:closeDocument()
            ui:onClose()
            ui = nil
        end
    end)

    it("keeps page turning after keyboard zoom out", function()
        ui.zooming:onZoom("out")
        ui.paging:onGotoPageRel(1)
        assert.are.equal(3, ui.paging.current_page)
    end)

    it("keeps panning or page turning after keyboard zoom in", function()
        ui.zooming:onZoom("in")
        local before = ui.paging.visible_area:copy()
        ui.paging:onGotoPageRel(1)
        local after = ui.paging.visible_area
        assert.is_true(ui.paging.current_page ~= 2 or before.x ~= after.x or before.y ~= after.y)
    end)

    it("keeps a valid configuration genus after keyboard zoom", function()
        ui.zooming:onZoom("out")
        assert.is_number(ui.document.configurable.zoom_mode_genus)
    end)

    it("preserves full-page manual geometry when cropping is disabled", function()
        ui.document.configurable.trim_page = 3
        ui.zooming:setZoom()
        local zoom = ui.zooming.zoom
        ui.zooming:onZoom("out")
        assert.are.near(zoom * 0.75, ui.zooming.zoom, 1e-6)
        assert.are.equal("manual", ui.doc_settings:readSetting("zoom_mode"))
    end)

    it("does not force continuous view into page view", function()
        ui:handleEvent(Event:new("SetScrollMode", true))
        local zoom = ui.zooming.zoom
        ui.zooming:onZoom("out")
        assert.is_true(ui.view.page_scroll)
        assert.are.equal("free", ui.zooming.zoom_mode)
        assert.are.near(zoom * 0.75, ui.zooming.zoom, 1e-6)
    end)

    it("retains the legacy reflow branch without changing its stored normal mode", function()
        -- Exercise the branch boundary without launching native PDF reflow.
        ui.document.configurable.text_wrap = 1
        local zoom = ui.zooming.zoom
        local normal_mode = ui.koptlistener.normal_zoom_mode
        ui.zooming:onZoom("out")
        assert.are.equal("free", ui.zooming.zoom_mode)
        assert.are.near(zoom * 0.75, ui.zooming.zoom, 1e-6)
        assert.are.equal(normal_mode, ui.koptlistener.normal_zoom_mode)
        ui.document.configurable.text_wrap = 0
    end)

    it("handles the real Shift-page-key event mapping", function()
        local Key = require("device/key")
        local zoom = ui.zooming.zoom
        ui:handleEvent(Event:new("KeyPress", Key:new("RPgFwd", { Shift = true })))
        assert.are.near(zoom * 1.333333, ui.zooming.zoom, 1e-6)
        assert.are.equal("manual", ui.zooming.zoom_mode)
    end)

    for _, rotation in ipairs({ 90, 270 }) do
        it("uses the rotated manual width at " .. rotation .. " degrees", function()
            ui.zooming:onRotationUpdate(rotation)
            local zoom = ui.zooming.zoom
            ui.zooming:onZoom("out")
            assert.are.near(zoom * 0.75, ui.zooming.zoom, 1e-6)
        end)
    end

    for _, mode in ipairs({ "page", "content", "pagewidth", "contentwidth", "manual" }) do
        it("preserves the requested scale when switching from " .. mode, function()
            ui.zooming:setZoomMode(mode, true)
            local zoom = ui.zooming.zoom
            ui.zooming:onZoom("in")
            assert.are.near(zoom * 1.333333, ui.zooming.zoom, 1e-6)
            assert.are.equal("manual", ui.zooming.zoom_mode)
            assert.are.equal("manual", ui.koptlistener.normal_zoom_mode)
            assert.are.near(ui.document.configurable.zoom_factor,
                ui.doc_settings:readSetting("kopt_zoom_factor"), 1e-6)
            ui.zooming:onZoom("out")
            assert.are.near(zoom * 1.333333 * 0.75, ui.zooming.zoom, 1e-6)
        end)
    end

    it("preserves manual zoom and paging after closing and reopening", function()
        ui.zooming:onZoom("out")
        local file, zoom = ui.document.file, ui.zooming.zoom
        ui:closeDocument()
        ui:onClose()
        ui = ReaderUI:new{ dimen = Screen:getSize(), document = DocumentRegistry:openDocument(file) }
        UIManager:show(ui)
        assert.are.equal("manual", ui.zooming.zoom_mode)
        assert.are.near(zoom, ui.zooming.zoom, 1e-6)
        ui.paging:onGotoPageRel(1)
        assert.are.equal(3, ui.paging.current_page)
    end)

    it("does not change temporary regional free-zoom navigation", function()
        ui.zooming:onToggleFreeZoom(nil, { pos = { x = 100, y = 100 } })
        assert.are.equal("free", ui.zooming.zoom_mode)
        local before = ui.paging.visible_area:copy()
        ui.paging:onGotoPageRel(1)
        assert.are.equal(2, ui.paging.current_page)
        assert.are.equal(before.x, ui.paging.visible_area.x)
        assert.are.equal(before.y, ui.paging.visible_area.y)
        ui.zooming:onToggleFreeZoom(nil, { pos = { x = 100, y = 100 } })
        assert.are.equal("page", ui.zooming.zoom_mode)
        ui.paging:onGotoPageRel(1)
        assert.are.equal(3, ui.paging.current_page)
    end)
end)
