describe("util.findFiles accepted file limit", function()
    local util, lfs, dir_stub, attr_stub, closes
    setup(function()
        require("commonrequire")
        util = require("util")
        lfs = require("libs/libkoreader-lfs")
    end)
    before_each(function()
        closes = 0
        local entries = {
            root = { ".", "..", "notes.txt", "._cover.png", "cover.png", "next.png", "subdir" },
            ["root/subdir"] = { ".", "..", "nested.png" },
        }
        dir_stub = stub(lfs, "dir", function(path)
            assert(entries[path], "unexpected directory")
            local index = 0
            return function()
                index = index + 1
                return entries[path][index]
            end, { close = function() closes = closes + 1 end }
        end)
        attr_stub = stub(lfs, "attributes", function(path)
            return { mode = (path:match("/%.%.?$") or entries[path]) and "directory" or "file" }
        end)
    end)
    after_each(function()
        dir_stub:revert()
        attr_stub:revert()
    end)

    it("counts only accepted files and stops before later candidates", function()
        local visited, images = {}, {}
        util.findFiles("root", function(path, name)
            visited[#visited + 1] = name
            if name == "notes.txt" or name:sub(1, 2) == "._" then return false end
            images[#images + 1] = path
            return true
        end, false, 1)
        assert.same({ "notes.txt", "._cover.png", "cover.png" }, visited)
        assert.same({ "root/cover.png" }, images)
        assert.equals(1, closes)
    end)

    it("preserves the legacy count for callbacks returning nil", function()
        local visited = {}
        util.findFiles("root", function(path) visited[#visited + 1] = path end, false, 1)
        assert.same({ "root/notes.txt" }, visited)
    end)

    it("continues to subdirectories after rejecting every parent file", function()
        local found = {}
        util.findFiles("root", function(path)
            if path ~= "root/subdir/nested.png" then return false end
            found[#found + 1] = path
            return true
        end, true, 1)
        assert.same({ "root/subdir/nested.png" }, found)
    end)

    it("keeps scanning without a limit when callbacks return false", function()
        local count = 0
        util.findFiles("root", function() count = count + 1 return false end, false)
        assert.equals(4, count)
    end)

    it("does not call the callback when the limit is zero", function()
        local callback = spy.new(function() end)
        util.findFiles("root", callback, true, 0)
        assert.spy(callback).was_not_called()
    end)

    it("bounds rejected entries independently of the accepted file count", function()
        local count = 0
        util.findFiles("root", function() count = count + 1 return false end, false, 1, 3)
        assert.equals(1, count) -- dot entries and the first rejected file exhaust the visit budget
        assert.equals(1, closes)
    end)
end)
