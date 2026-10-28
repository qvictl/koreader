return {
    name = "Controlled transport lifetime probe",
    timeout = 60,
    run = function(T)
        local Buffer = require("string.buffer")
        local original_decode = Buffer.decode
        local gains = {}
        local repository = T.spec_dir:gsub("/spec/integration$", "")
        local quoted = "'" .. repository:gsub("'", "'\\''") .. "'"
        local git = assert(io.popen("git -C " .. quoted .. " show fec96036b:frontend/ui/trapper.lua", "r"))
        local previous = git:read("*all")
        git:close()
        local ok, err = xpcall(function()
            local selected = os.getenv("TRANSPORT_PROBE_MODE")
            for _, name in ipairs(selected and { selected } or { "before", "after" }) do
                local Trapper = name == "before"
                    and assert(loadstring(previous, "@frontend/ui/trapper.lua"))()
                    or dofile("frontend/ui/trapper.lua")
                T:wait(0.1)
                collectgarbage("collect")
                local initial = collectgarbage("count")
                Buffer.decode = function(data)
                    if #data > 6 * 1024 * 1024 then
                        collectgarbage("collect")
                        gains[name] = collectgarbage("count") - initial
                        T:metric(name .. "_live_heap_absolute_kib", collectgarbage("count"), "KiB")
                    end
                    return original_decode(data)
                end
                local done, completed, value = false
                T:run(function()
                    Trapper:wrap(function()
                        completed, value = Trapper:dismissableRunInSubprocess(function()
                            local parts = {}
                            for i = 1, 1024 do
                                parts[i] = string.format("%08d", i)
                                    .. string.rep(string.char(65 + i % 26), 8192 - 8)
                            end
                            return { data = table.concat(parts) }
                        end, "Transport lifetime probe")
                        done = true
                    end)
                end)
                T:waitUntil(function() return done end, 20, "large decoded result")
                Buffer.decode = original_decode
                T:check(completed and #value.data == 8 * 1024 * 1024, name .. " preserves data")
                T:metric(name .. "_live_heap_delta_kib", gains[name], "KiB")
                value = nil
            end
            if gains.before and gains.after then
                T:metric("reclaimed_before_decode_kib", gains.before - gains.after, "KiB")
                T:check(gains.before - gains.after > 7 * 1024, "transport chunks are eligible before decode")
            end
        end, debug.traceback)
        Buffer.decode = original_decode
        if not ok then error(err, 0) end
    end,
}
