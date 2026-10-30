-- Cached synthetic page maps and PDF highlight arrows after a hold gesture.
local function writePDF(path)
    local content = "BT /F1 16 Tf 40 700 Td (alpha beta gamma delta) Tj 0 -30 Td (additional fixture words) Tj ET"
    local objects = {
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Length " .. #content .. " >>\nstream\n" .. content .. "\nendstream",
    }
    local pdf, offsets = "%PDF-1.4\n", {}
    for i, object in ipairs(objects) do
        offsets[i] = #pdf
        pdf = pdf .. i .. " 0 obj\n" .. object .. "\nendobj\n"
    end
    local xref = #pdf
    pdf = pdf .. "xref\n0 6\n0000000000 65535 f \n"
    for _, offset in ipairs(offsets) do pdf = pdf .. string.format("%010d 00000 n \n", offset) end
    pdf = pdf .. "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n" .. xref .. "\n%%EOF\n"
    local file = assert(io.open(path, "wb"))
    file:write(pdf)
    file:close()
end

return {
    name = "Synthetic page-map cache and PDF highlight holds",
    timeout = 90,
    run = function(T)
        T:run(function()
            local ffi = require("ffi")
            local BB = require("ffi/blitbuffer")
            local Mupdf = require("ffi/mupdf")
            local RenderImage = require("ui/renderimage")
            local slot, backend
            for i = 1, 20 do
                local name, value = debug.getupvalue(Mupdf.scaleBlitBuffer, i)
                if not name then break end
                if name == "W" then slot, backend = i, value; break end
            end
            assert(slot, "MuPDF pixmap backend is available")
            local calls = 0
            local guard = setmetatable({
                mupdf_new_pixmap_with_data = function(ctx, colorspace, w, h, seps, alpha, stride, data)
                    -- Stop invalid layouts at the Lua boundary, before native memory access.
                    assert(stride == w * 4, "RGB565 conversion must use the RGBA buffer stride")
                    calls = calls + 1
                    return backend.mupdf_new_pixmap_with_data(ctx, colorspace, w, h, seps, alpha, stride, data)
                end,
            }, { __index = backend })
            local legacy = G_reader_settings:readSetting("legacy_image_scaling")
            G_reader_settings:saveSetting("legacy_image_scaling", false)
            debug.setupvalue(Mupdf.scaleBlitBuffer, slot, guard)
            local input, scaled
            local ok, err = xpcall(function()
                for _, stride in ipairs({ 24, 32, 64 }) do
                    input = BB.new(12, 8, BB.TYPE_BBRGB16, nil, stride, stride / 2)
                    input:paintRectRGB32(0, 0, 12, 8, BB.ColorRGB32(255, 0, 0, 255))
                    input:paintRectRGB32(6, 0, 6, 8, BB.ColorRGB32(0, 0, 255, 255))
                    local before = ffi.string(input.data, input.stride * input.h)
                    scaled = RenderImage:scaleBlitBuffer(input, 6, 4, false)
                    T:eq(scaled.w, 6, "RGB565 image scales to the requested width")
                    T:eq(scaled.h, 4, "RGB565 image scales to the requested height")
                    local left = scaled:getPixel(0, 0):getColorRGB24()
                    local right = scaled:getPixel(5, 3):getColorRGB24()
                    T:eq(left:getR(), 255, "scaled RGB565 image retains red pixels")
                    T:eq(left:getB(), 0, "red pixels do not pick up blue")
                    T:eq(right:getR(), 0, "blue pixels do not pick up red")
                    T:eq(right:getB(), 255, "scaled RGB565 image retains blue pixels")
                    T:eq(input:getAllocated(), 1, "image scaling preserves caller-owned source")
                    T:check(ffi.string(input.data, input.stride * input.h) == before, "source pixels and padding remain unchanged")
                    scaled:free(); scaled = nil
                    input:free(); input = nil
                end
                T:eq(calls, 3, "all RGB565 layouts reach the real MuPDF backend")
            end, debug.traceback)
            debug.setupvalue(Mupdf.scaleBlitBuffer, slot, backend)
            if legacy == nil then G_reader_settings:delSetting("legacy_image_scaling")
            else G_reader_settings:saveSetting("legacy_image_scaling", legacy) end
            if scaled then scaled:free() end
            if input then input:free() end
            assert(ok, err)
        end)
        local reader = T:openBook(T:fixture("books/en.epub"))
        T:run(function()
            local doc = reader.document
            doc:buildSyntheticPageMap(2048)
            T:eq(doc:getSyntheticPageMapCharsPerPage(), 2048, "initial synthetic page size is cached")
            local old_count = #doc:getPageMap()
            local old_last = doc:getPageMapLastPageLabel()
            doc:buildSyntheticPageMapIfNoneDocumentProvided(512)
            T:eq(doc:getSyntheticPageMapCharsPerPage(), 512, "legacy rebuild invalidates cached page size")
            T:check(#doc:getPageMap() > old_count, "legacy rebuild invalidates the cached page map")
            T:check(doc:getPageMapLastPageLabel() ~= old_last, "legacy rebuild refreshes page labels")
        end)
        T:closeBook()

        local path = os.getenv("KO_HOME") .. "/highlight-boundaries.pdf"
        writePDF(path)
        reader = T:openBook(path)
        local index
        T:run(function()
            local doc = reader.document
            local line = doc:getTextBoxes(1)[1]
            T:eq(#line, 4, "synthetic PDF has four selectable words")
            local function position(box)
                return { page = 1, x = (box.x0 + box.x1) / 2, y = (box.y0 + box.y1) / 2 }
            end
            reader.highlight.selected_text = doc:getTextFromPositions(position(line[2]), position(line[3]))
            index = reader.highlight:saveHighlight()
            reader.highlight:clear()
            T:eq(reader.annotation.annotations[index].text, "beta gamma", "middle words are highlighted")
            reader.highlight:showHighlightDialog(index)
        end)
        T:repaint()
        local arrow = T:findWidget(T:topWidget(), function(widget)
            return widget.text == "▒▒▷" and widget.callback
        end)
        T:check(arrow and arrow.dimen, "PDF highlight end arrow is painted")
        T:run(function()
            local Geom = require("ui/geometry")
            local Event = require("ui/event")
            local d = arrow.dimen
            require("ui/uimanager"):sendEvent(Event:new("Gesture", {
                ges = "hold", time = require("ui/time").now(),
                pos = Geom:new{ x = d.x + d.w / 2, y = d.y + d.h / 2, w = 0, h = 0 },
            }))
        end)
        T:eq(reader.annotation.annotations[index].text, "beta gamma", "holding does not request unsupported PDF character moves")
        T:tapWidget(arrow, "PDF end boundary after a hold")
        T:eq(reader.annotation.annotations[index].text, "beta gamma delta", "normal arrow taps still adjust PDF highlights after a hold")
        T:run(function() require("ui/uimanager"):close(T:topWidget()) end)
        T:closeBook()
    end,
}
