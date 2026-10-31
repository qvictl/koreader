describe("ReaderZooming partial setting updates", function()
    local DataStorage, DocumentRegistry, Event, ReaderUI, Screen, UIManager, lfs
    local ui, root, serial, owns_root, PluginLoader, saved_plugins, saved_disable_double_tap, saved_default
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
        root = DataStorage:getDataDir() .. "/zoom-current-spec"
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
        saved_default = G_reader_settings:readSetting("kopt_zoom_factor")
        G_reader_settings:saveSetting("kopt_zoom_factor", 2)
        saved_disable_double_tap = rawget(require("device").input, "disable_double_tap")
        serial = serial + 1
        local file = root .. "/" .. serial .. ".pdf"
        files[#files + 1] = file
        local stream = "BT /F1 18 Tf 60 700 Td (Synthetic current zoom test) Tj ET\n"
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
        G_reader_settings:saveSetting("kopt_zoom_factor", saved_default)
        if ui then
            ui:closeDocument()
            ui:onClose()
            ui = nil
        end
        require("device").input.disable_double_tap = saved_disable_double_tap
    end)

    local function manual(factor)
        ui.zooming:setZoomMode("manual", true)
        ui.document.configurable.zoom_factor = factor
        ui.zooming:onDefineZoom(factor)
    end

    it("retains a current manual factor on the next and previous page", function()
        manual(0.7)
        local zoom = ui.zooming.zoom
        ui.paging:onGotoPage(3)
        assert.are.near(zoom, ui.zooming.zoom, 1e-6)
        assert.are.near(0.7, ui.doc_settings:readSetting("kopt_zoom_factor"), 1e-6)
        ui.paging:onGotoPage(2)
        assert.are.near(zoom, ui.zooming.zoom, 1e-6)
        assert.are.equal(2, G_reader_settings:readSetting("kopt_zoom_factor"))
    end)

    it("does not erase the factor during a mode-only update", function()
        ui.zooming:onSetZoomPan({ kopt_zoom_factor = 0.7, zoom_mode = "manual" })
        ui.zooming:onSetZoomPan({ zoom_mode = "manual" }, true)
        assert.are.equal(0.7, ui.doc_settings:readSetting("kopt_zoom_factor"))
        assert.are.equal("manual", ui.doc_settings:readSetting("zoom_mode"))
    end)

    it("does not erase the mode during a factor-only update", function()
        ui.zooming:onSetZoomPan({ zoom_mode = "manual", kopt_zoom_factor = 1.3 })
        ui.zooming:onSetZoomPan({ kopt_zoom_factor = 0.7 }, true)
        assert.are.equal("manual", ui.doc_settings:readSetting("zoom_mode"))
        assert.are.equal(0.7, ui.doc_settings:readSetting("kopt_zoom_factor"))
    end)

    for _, field in ipairs({ "zoom_overlap_h", "zoom_overlap_v", "zoom_bottom_to_top", "zoom_direction_vertical" }) do
        it("preserves the current mode and factor when changing " .. field, function()
            ui.zooming:onSetZoomPan({ zoom_mode = "manual", kopt_zoom_factor = 0.7 })
            local value = field:find("overlap") and 25 or true
            ui.zooming:onSetZoomPan({ [field] = value })
            assert.are.equal(0.7, ui.doc_settings:readSetting("kopt_zoom_factor"))
            assert.are.equal("manual", ui.doc_settings:readSetting("zoom_mode"))
            assert.are.equal(value, ui.zooming[field])
        end)
    end

    it("keeps an empty update from deleting saved settings", function()
        ui.zooming:onSetZoomPan({ zoom_mode = "manual", kopt_zoom_factor = 0.7 }, true)
        ui.zooming:onSetZoomPan({}, true)
        assert.are.equal(0.7, ui.doc_settings:readSetting("kopt_zoom_factor"))
        assert.are.equal("manual", ui.doc_settings:readSetting("zoom_mode"))
    end)

    it("still replaces explicitly supplied mode and factor", function()
        ui.zooming:onSetZoomPan({ zoom_mode = "manual", kopt_zoom_factor = 0.7 }, true)
        ui.zooming:onSetZoomPan({ zoom_mode = "columns", kopt_zoom_factor = 1.4 }, true)
        assert.are.equal(1.4, ui.doc_settings:readSetting("kopt_zoom_factor"))
        assert.are.equal("columns", ui.doc_settings:readSetting("zoom_mode"))
        assert.are.equal(1.4, ui.document.configurable.zoom_factor)
    end)

    it("retains repeated manual changes across close and reopen", function()
        manual(0.7)
        manual(1.1)
        manual(0.9)
        local zoom, file = ui.zooming.zoom, ui.document.file
        ui:closeDocument()
        ui:onClose()
        ui = ReaderUI:new{ dimen = Screen:getSize(), document = DocumentRegistry:openDocument(file) }
        UIManager:show(ui)
        assert.are.equal("manual", ui.zooming.zoom_mode)
        ui.paging:onGotoPage(3)
        assert.are.near(zoom, ui.zooming.zoom, 1e-6)
        assert.are.equal(0.9, ui.doc_settings:readSetting("kopt_zoom_factor"))
    end)

    for _, mode in ipairs({ "columns", "rows" }) do
        it("preserves the existing " .. mode .. " configuration flow", function()
            ui.document.configurable.zoom_mode_genus = mode == "columns" and 2 or 1
            ui.zooming:onDefineZoom(mode)
            ui.document.configurable.zoom_range_number = 2.5
            ui.zooming:onDefineZoom(2.5)
            local zoom = ui.zooming.zoom
            ui.paging:onGotoPage(3)
            assert.are.equal(mode, ui.zooming.zoom_mode)
            assert.are.near(zoom, ui.zooming.zoom, 1e-6)
            assert.are.equal(2, G_reader_settings:readSetting("kopt_zoom_factor"))
        end)
    end
    it("leaves absent mode and factor absent for unrelated settings", function()
        ui.doc_settings:delSetting("kopt_zoom_factor")
        ui.doc_settings:delSetting("zoom_mode")
        ui.zooming:onSetZoomPan({ zoom_overlap_h = 30 }, true)
        assert.is_nil(ui.doc_settings:readSetting("kopt_zoom_factor"))
        assert.is_nil(ui.doc_settings:readSetting("zoom_mode"))
    end)

    it("retains a current factor without any global override", function()
        G_reader_settings:delSetting("kopt_zoom_factor")
        manual(0.7)
        local zoom = ui.zooming.zoom
        ui.paging:onGotoPage(3)
        assert.are.near(zoom, ui.zooming.zoom, 1e-6)
    end)

    it("preserves the no-redraw contract for partial updates", function()
        local redraw = stub(ui, "handleEvent")
        ui.zooming:onSetZoomPan({ zoom_overlap_h = 25 }, true)
        assert.spy(redraw).was_not_called()
        ui.zooming:onSetZoomPan({ zoom_overlap_h = 30 })
        redraw:revert()
        assert.stub(redraw).was.called(1)
    end)
end)
