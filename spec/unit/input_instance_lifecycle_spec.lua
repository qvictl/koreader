describe("Input instance state", function()
    local Input, Device

    setup(function()
        require("commonrequire")
        Input = require("device/input")
        Device = require("device")
    end)

    local function newInput()
        return Input:new{
            device = { screen = Device.screen, isSDL = function() return false end },
            input = {},
            event_map = { [42] = "Shift" },
        }
    end

    it("does not inherit another instance's held modifiers", function()
        local first, second = newInput(), newInput()
        finally(function() first:handleKeyBoardEv{ code = 42, value = 0, fd = 0 } end)
        first:handleKeyBoardEv{ code = 42, value = 1, fd = 0 }
        assert.is_true(first.modifiers.Shift)
        assert.is_false(second.modifiers.Shift)
    end)

    it("keeps USB payload queues and rotation exceptions local", function()
        local first, second = newInput(), newInput()
        local queue = first.fake_event_args.UsbDevicePlugIn
        local before = #queue
        finally(function()
            while #queue > before do table.remove(queue) end
            first.rotation_ignored_fds[-5432] = nil
        end)
        assert.are.equal("UsbDevicePlugIn", first:handleKeyBoardEv{ code = 10040, value = 17, fd = 0 })
        first.rotation_ignored_fds[-5432] = true
        assert.are.equal(0, #second.fake_event_args.UsbDevicePlugIn)
        assert.is_nil(second.rotation_ignored_fds[-5432])
    end)

    it("does not duplicate configured Back keys when inputs are recreated", function()
        local previous = G_reader_settings:readSetting("backspace_as_back")
        local defaults = {}
        for i, value in ipairs(Input.group.Back) do defaults[i] = value end
        finally(function()
            G_reader_settings:saveSetting("backspace_as_back", previous)
            for i = #Input.group.Back, 1, -1 do Input.group.Back[i] = nil end
            for i, value in ipairs(defaults) do Input.group.Back[i] = value end
        end)
        G_reader_settings:makeTrue("backspace_as_back")
        local first, second = newInput(), newInput()
        local function backspaces(input)
            local n = 0
            for _, value in ipairs(input.group.Back) do
                if value == "Backspace" then n = n + 1 end
            end
            return n
        end
        assert.are.equal(1, backspaces(first))
        assert.are.equal(1, backspaces(second))
    end)

    it("keeps gesture contacts and previous taps local", function()
        local first, second = newInput().gesture_detector, newInput().gesture_detector
        finally(function()
            first:dropContacts()
            first.previous_tap[0] = nil
        end)
        local contact = first:newContact(0)
        first.previous_tap[0] = { x = 10, y = 20 }
        assert.are.equal(contact, first:getContact(0))
        assert.is_nil(second:getContact(0))
        assert.is_nil(second.previous_tap[0])
        assert.are.equal(0, second.contact_count)
    end)
end)
