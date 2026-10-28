return {
    name = "File operations report failed execution without flushing parent files",
    timeout = 60,
    run = function(T)
        local ffi = require("ffi")
        local util = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local C = ffi.C
        local fm = T:fileManager()
        local dir = T:fixture("exec-failures")
        require("util").makePath(dir)
        local source, copied, moved = dir .. "/source.txt", dir .. "/copy.txt", dir .. "/moved.txt"
        local f = assert(io.open(source, "w")); f:write("fixture content"); f:close()
        local cp, mv = fm.cp_bin, fm.mv_bin
        local function read(path)
            local r = assert(io.open(path, "r")); local data = r:read("*all"); r:close(); return data
        end
        local index, original
        for i = 1, 30 do
            local name, value = debug.getupvalue(util.execute, i)
            if name == "C" then index, original = i, value; break end
        end
        local function fault(overrides, action)
            debug.setupvalue(util.execute, index, setmetatable(overrides, { __index = original }))
            local ok, err = xpcall(action, debug.traceback)
            debug.setupvalue(util.execute, index, original)
            if not ok then error(err, 0) end
        end
        local ok, err = xpcall(function()
            local buffer = assert(io.open(dir .. "/buffer.txt", "w"))
            buffer:setvbuf("full", 1024)
            buffer:write("parent-buffer")
            fm.cp_bin = dir .. "/missing-copy-program"
            local copied_ok = T:run(function() return fm:copyFileFromTo(source, copied) end)
            buffer:close()
            T:check(not copied_ok, "missing copy program reports failure")
            T:eq(read(dir .. "/buffer.txt"), "parent-buffer", "child does not flush inherited buffers")
            T:check(not lfs.attributes(copied), "failed exec creates no destination")
            fm.cp_bin = cp

            local failed_fork_waits = 0
            T:run(function()
                fault({ fork = function() return -1 end, waitpid = function()
                    failed_fork_waits = failed_fork_waits + 1
                    return -1
                end }, function()
                    T:check(not fm:copyFileFromTo(source, copied), "fork failure does not report copy success")
                    T:check(not fm:moveFile(source, moved), "fork failure does not report move success")
                    T:check(not fm:copyRecursive(source, copied), "fork failure does not report recursive copy success")
                end)
            end)
            T:eq(failed_fork_waits, 0, "fork failure never waits for an unrelated child")
            T:check(lfs.attributes(source) and not lfs.attributes(moved), "failed move preserves source")
            local waits = 0
            T:run(function()
                fault({
                    fork = function() return 123 end,
                    waitpid = function(pid, status)
                        T:eq(pid, 123, "wait retries the original child")
                        waits = waits + 1
                        if waits == 1 then ffi.errno(C.EINTR); return -1 end
                        status[0] = 3 * 256
                        return 123
                    end,
                }, function()
                    T:check(not fm:copyFileFromTo(source, copied), "interrupted wait preserves command failure")
                end)
            end)
            T:eq(waits, 2, "interrupted wait retries the same child")
            T:run(function()
                fault({ fork = function() return 123 end, waitpid = function()
                    ffi.errno(C.EINVAL)
                    return -1
                end }, function()
                    T:check(not fm:copyFileFromTo(source, copied), "uncollected child status is not success")
                end)
            end)
            T:check(not lfs.attributes(copied), "failed wait creates no destination")
            T:check(T:run(function() return fm:copyFileFromTo(source, copied) end), "normal copy succeeds")
            T:eq(read(copied), "fixture content", "normal copy preserves content")
            T:check(T:run(function() return fm:moveFile(copied, moved) end), "normal move succeeds")
            T:check(not lfs.attributes(copied), "normal move removes old name")
            T:eq(read(moved), "fixture content", "normal move preserves content")
        end, debug.traceback)
        fm.cp_bin, fm.mv_bin = cp, mv
        debug.setupvalue(util.execute, index, original)
        util.purgeDir(dir)
        if not ok then error(err, 0) end
    end,
}
