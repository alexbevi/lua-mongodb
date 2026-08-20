local ROOT = os.getenv("PWD") or "."

package.path = ROOT .. "/src/?.lua;" .. ROOT .. "/src/?/init.lua;" .. package.path

local copas = require("copas")
local mongodb = require("mongodb")

local uri = arg[1] or os.getenv("MONGODB_COMPATIBILITY_URI")

assert(type(uri) == "string" and uri ~= "", "compatibility probe requires a URI")

local outcome

copas.loop(function()
  outcome = table.pack(pcall(function()
    local client = assert(mongodb.client(uri, {
      compressors = { "zlib" },
      runtime = mongodb.runtime.copas(),
      server_selection_timeout_ms = 5000,
    }))
    local reply = assert(client:database("admin"):run_command("ping"))

    assert(reply:get("ok"):to_number() == 1, "compatibility ping did not succeed")
    assert(client:close())
  end))
end)

if not outcome[1] then
  io.stderr:write("compatibility probe: " .. tostring(outcome[2]) .. "\n")
  os.exit(1)
end

print("compatibility probe: public client ping passed")
