return {
    name = "Screensaver image limit ignores unrelated files",
    timeout = 60,
    settings = {
        screensaver_type = "random_image",
        screensaver_show_message = false,
        screensaver_delay = "disable",
        screensaver_max_files = 1,
    },
    run = function(T)
        local Screensaver = require("ui/screensaver")
        local Device = require("device")
        local lfs = require("libs/libkoreader-lfs")
        local ffiUtil = require("ffi/util")
        local dir = T:fixture("screensaver-images")
        require("util").makePath(dir)
        for _, name in ipairs{ "00-notes.txt", "._cover.png", "20-cover.png", "30-cover.png" } do
            ffiUtil.copyFile("resources/koreader.png", dir .. "/" .. name)
        end
        local real_dir = lfs.dir
        -- Fix enumeration order, while using real files, decoding and widgets.
        -- File systems need not return directory entries in creation order.
        local function ordered_dir(path)
            if path ~= dir then return real_dir(path) end
            local names = {}
            for name in real_dir(path) do names[#names + 1] = name end
            table.sort(names)
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end
        local ok, err = xpcall(function()
            T:run(function()
                G_reader_settings:saveSetting("screensaver_dir", dir)
                lfs.dir = ordered_dir
            end)
            for _, alphabetical in ipairs{ true, false } do
                T:run(function()
                    G_reader_settings:saveSetting("screensaver_cycle_images_alphabetically", alphabetical)
                    Screensaver:setup()
                    T:eq(Screensaver.image_file, dir .. "/20-cover.png", "image selected after unrelated files")
                    Screensaver:show()
                end)
                T:repaint()
                T:check(Device.screen_saver_mode, "screensaver is painted")
                T:run(function() Screensaver:close() end)
                T:check(not Device.screen_saver_mode, "screensaver closes normally")
            end
        end, debug.traceback)
        T:run(function()
            lfs.dir = real_dir
            Screensaver:close()
            Screensaver:cleanup()
        end)
        if not ok then error(err, 0) end
    end,
}
