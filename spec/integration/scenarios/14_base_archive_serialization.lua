-- Package and reload serializer output with the real archive implementation.
-- Locale correction must preserve special-number values, and archive failures
-- must retain diagnostics without poisoning subsequent writes.
return {
    name = "Base archive and radix-safe serialization",
    timeout = 60,
    run = function(T)
        T:run(function()
            local Archiver = require("ffi/archiver")
            local serpent = require("ffi/serpent")
            local path = os.getenv("KO_HOME") .. "/serialized-values.zip"
            local values = { math.huge, -math.huge, 0/0, 1.5, "synthetic payload" }
            local payload = serpent.dump(values, { fixradix = true })
            local writer = Archiver.Writer:new()
            T:check(writer:open(path), "archive writer opens")
            T:check(not writer:addPath("missing", os.getenv("KO_HOME") .. "/missing-source"),
                "a missing archive source fails")
            T:check(type(writer.err) == "string" and writer.err ~= "", "archive source error is retained")
            T:check(writer:addFileFromMemory("values.lua", payload), "writer recovers after a failed source")
            T:eq(writer.err, nil, "successful write clears the previous error")
            writer:close()

            local reader = Archiver.Reader:new()
            T:check(reader:open(path), "archive reader opens")
            T:eq(reader:next().path, "values.lua", "serialized entry is indexed")
            local contents = reader:extractToMemory("values.lua")
            reader:close()
            T:eq(contents, payload, "archive preserves the serialized bytes")
            local ok, restored = serpent.load(contents)
            T:check(ok, "serialized archive payload can be loaded")
            T:eq(restored[1], math.huge, "positive infinity survives")
            T:eq(restored[2], -math.huge, "negative infinity survives")
            T:check(restored[3] ~= restored[3], "NaN survives")
            T:eq(restored[4], 1.5, "fraction survives")
            T:eq(restored[5], "synthetic payload", "text survives")
            os.remove(path)
        end)
    end,
}
