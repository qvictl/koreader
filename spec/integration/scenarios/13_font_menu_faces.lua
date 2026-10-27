-- Font menu previews: drawing every font of the menu with its own face must not keep all
-- those faces cached (they used to stay in Font.faces forever, a few MB each for CJK fonts).
return {
    name = "Font menu preview faces are not cached",
    timeout = 120,
    settings = {
        font_menu_use_font_face = true,
    },
    run = function(T)
        local Blitbuffer = require("ffi/blitbuffer")
        local Font = require("ui/font")
        local TextWidget = require("ui/widget/textwidget")
        local ui = T:openBook(T:fixture("books/en.epub"))
        if not ui.font.face_table then
            T:run(function() ui.font:setupFaceMenuTable() end)
        end
        local function nbFaces()
            local n = 0
            for _ in pairs(Font.faces) do n = n + 1 end
            return n
        end
        local function drawPreviews()
            local bb = Blitbuffer.new(800, 100, Blitbuffer.TYPE_BB8)
            local n = 0
            for _, item in ipairs(ui.font.face_table) do
                if item.font_func then
                    local face = item.font_func(24)
                    if face then
                        local text = type(item.text) == "string" and item.text or (item.text_func and item.text_func()) or "font"
                        local tw = TextWidget:new{ text = text, face = face }
                        tw:paintTo(bb, 0, 0)
                        tw:free()
                        n = n + 1
                    end
                end
            end
            bb:free()
            return n
        end
        local faces_before = nbFaces()
        local lua_before = T:luaKb()
        local t0 = T:now()
        local n = T:run(drawPreviews)
        T:metric("font_previews", n)
        T:budget("font_menu_previews_ms", T:now() - t0, 10000, "ms")
        T:check(n >= 5, "previews drawn for the font menu entries (" .. n .. ")")
        T:run(drawPreviews)
        local faces_after = nbFaces()
        T:log("Font.faces:", faces_before, "->", faces_after)
        T:check(faces_after <= faces_before + 2, "preview faces are not kept in Font.faces")
        T:budget("lua_heap_growth_kb", T:luaKb() - lua_before, 2048, "kB")
        T:closeBook()
    end,
}
