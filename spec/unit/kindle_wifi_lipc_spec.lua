-- Kindle lipc Wi-Fi backend: wifid may hand back NULL hasharrays (to_table() -> nil),
-- e.g. while it's busy or switching networks; listing networks must not throw then
-- (a Lua error here aborts the whole connection attempt from NetworkMgr).
-- luacheck: ignore 122 143
describe("Kindle lipc Wi-Fi with NULL hasharrays", function()
    local iopen = io.open
    local hash_props
    local NetworkMgr

    local function handle()
        return {
            get_string_property = function(_, _, prop)
                if prop == "scanState" then return "idle" end
                if prop == "cmState" then return "READY" end
                if prop == "load" then return "screensaver" end
            end,
            set_string_property = function() end,
            set_int_property = function() end,
            get_int_property = function() end,
            register_int_property = function() return {} end,
            close = function() end,
            new_hasharray = function() return { destroy = function() end } end,
            access_hash_property = function(_, _, prop)
                local v = hash_props[prop]
                return { to_table = function() return v end, destroy = function() end }
            end,
        }
    end

    setup(function()
        require("commonrequire")
        package.loaded["liblipclua"] = { init = handle }
        package.loaded["libopenlipclua"] = { open_no_name = handle }
        package.loaded["ffi/framebuffer_mxcfb"] = { new = function() return {} end }
        io.open = function(filename, mode)
            if filename == "/proc/usid" then
                return { read = function() return "G001Q0XX" end, close = function() end }
            end
            return iopen(filename, mode)
        end
        package.loaded["device/kindle/device"] = nil
        local Kindle = require("device/kindle/device")
        io.open = iopen
        NetworkMgr = {}
        Kindle:initNetworkManager(NetworkMgr)
    end)

    teardown(function()
        io.open = iopen
        package.loaded["liblipclua"] = nil
        package.loaded["libopenlipclua"] = nil
        package.loaded["ffi/framebuffer_mxcfb"] = nil
        package.loaded["device/kindle/device"] = nil
    end)

    before_each(function()
        hash_props = {
            scanList = { { essid = "Home", netid = 1, known = "yes", signal = 4, signal_max = 5, key_mgmt = "wpa2-psk" } },
            profileData = { { essid = "Home", netid = 1, psk = "pw" } },
            currentEssid = { { essid = "Home", netid = 1 } },
        }
    end)

    it("lists networks normally", function()
        local list = NetworkMgr:getNetworkList()
        assert.are.equal("pw", list[1].password)
        assert.is_true(list[1].connected)
        assert.are.same({ ssid = "Home" }, NetworkMgr:getCurrentNetwork())
    end)

    it("treats a NULL current network hasharray as not connected", function()
        hash_props.currentEssid = nil
        local list = NetworkMgr:getNetworkList()
        assert.are.equal(1, #list)
        assert.is_falsy(list[1].connected)
        assert.is_nil(NetworkMgr:getCurrentNetwork())
    end)

    it("treats a NULL saved profiles hasharray as no saved password", function()
        hash_props.profileData = nil
        local list = NetworkMgr:getNetworkList()
        assert.are.equal(1, #list)
        assert.is_nil(list[1].password)
    end)
end)
