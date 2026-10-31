-- luacheck: ignore 122 -- restored synthetic os.execute boundary
-- InkView and command execution are synthetic; no device logo or host command is touched.
describe("Cover image PocketBook boot-logo preference", function()
    local CoverImage, Device, ffi, commands, reads, preference, config, fail
    local saved_pocketbook, saved_execute, saved_inkview, saved_preload
    local plugin

    setup(function()
        require("commonrequire")
        Device = require("device")
        ffi = require("ffi")
        saved_pocketbook, saved_execute = Device.isPocketBook, os.execute
        saved_inkview, saved_preload = package.loaded["ffi/inkview"], package.preload["ffi/inkview"]
        CoverImage = dofile("plugins/coverimage.koplugin/main.lua")
    end)

    teardown(function()
        Device.isPocketBook, os.execute = saved_pocketbook, saved_execute
        package.loaded["ffi/inkview"], package.preload["ffi/inkview"] = saved_inkview, saved_preload
    end)

    before_each(function()
        preference, config, fail = "@cover_logo", {}, nil
        commands, reads = {}, {}
        Device.isPocketBook = function() return true end
        os.execute = function(command) commands[#commands + 1] = command; return 0 end
        package.loaded["ffi/inkview"] = {
            GetGlobalConfig = function()
                if fail == "config" then error("synthetic unavailable config") end
                return config
            end,
            ReadString = function(actual_config, key, default)
                assert.equals(config, actual_config)
                reads[#reads + 1] = { key, default }
                if fail == "read" then error("synthetic missing ReadString symbol") end
                if preference == nil then return ffi.cast("const char *", 0) end
                return ffi.new("char[?]", #preference + 1, preference)
            end,
        }
        plugin = setmetatable({ cover_image_path = "/tmp/synthetic cover.bmp" }, { __index = CoverImage })
    end)

    for _, value in ipairs({ "@default_boot_logo", "@random_logo", "@current_page", "/synthetic/custom.bmp", "", "@COVER_LOGO", "@cover_logo " }) do
        it("leaves the firmware logo untouched for " .. value, function()
            preference = value
            plugin:updatePocketBookBootLogo()
            assert.same({}, commands)
            assert.same({ { "bootlogo", "@default_boot_logo" } }, reads)
        end)
    end

    it("retains sync and the escaped background command only for the exact cover selection", function()
        plugin:updatePocketBookBootLogo()
        assert.same({ "sync", "iv2sh WriteStartupLogo " .. require("util").shell_escape({ plugin.cover_image_path }) .. " &" }, commands)
        assert.equals(1, #reads)
    end)

    it("re-reads the firmware preference instead of caching an earlier cover selection", function()
        plugin:updatePocketBookBootLogo()
        preference = "@default_boot_logo"
        plugin:updatePocketBookBootLogo()
        preference = "@cover_logo"
        plugin:updatePocketBookBootLogo()
        assert.equals(3, #reads)
        assert.equals(4, #commands)
    end)

    it("does not query InkView or execute commands on other devices", function()
        Device.isPocketBook = function() return false end
        fail = "config"
        plugin:updatePocketBookBootLogo()
        assert.same({}, commands)
        assert.same({}, reads)
    end)

    it("does not dereference a NULL configuration", function()
        config = ffi.cast("void *", 0)
        plugin:updatePocketBookBootLogo()
        assert.same({}, commands)
        assert.same({}, reads)
    end)

    it("does not dereference a NULL setting", function()
        preference = nil
        plugin:updatePocketBookBootLogo()
        assert.same({}, commands)
        assert.equals(1, #reads)
    end)

    for _, operation in ipairs({ "config", "read" }) do
        it("does not replace the logo or crash when " .. operation .. " fails", function()
            fail = operation
            plugin:updatePocketBookBootLogo()
            assert.same({}, commands)
        end)
    end

    it("does not crash or replace the logo when the SDK cannot be loaded", function()
        package.loaded["ffi/inkview"] = nil
        package.preload["ffi/inkview"] = function() error("synthetic unavailable SDK") end
        plugin:updatePocketBookBootLogo()
        assert.same({}, commands)
    end)
end)
