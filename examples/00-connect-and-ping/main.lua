local mongodb = require("mongodb")

local function supported_version(version)
  local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")

  if major == nil then
    return false
  end

  major = tonumber(major)
  minor = tonumber(minor)
  patch = tonumber(patch)

  return major > 0 or minor > 5 or minor == 5 and patch >= 0
end

local function ping()
  local uri = os.getenv("MONGODB_URI")
    or "mongodb://127.0.0.1:27017/lua_examples_ping"

  return mongodb.run(function()
    local client, err = mongodb.client(uri, { app_name = "lua-connect-and-ping" })

    if not client then
      return nil, err
    end

    local reply
    reply, err = client:database("admin"):run_command(
      mongodb.bson.document({ { "ping", 1 } })
    )

    if not reply then
      client:close()
      return nil, err
    end

    local closed
    closed, err = client:close()

    if not closed then
      return nil, err
    end

    print("MongoDB driver 0.5.0 or later loaded from LuaRocks")
    print("Ping succeeded")
    print("Client closed")
    return true
  end)
end

if not supported_version(mongodb._VERSION) then
  io.stderr:write("mongodb 0.5.0 or later is required\n")
  os.exit(1)
end

local ok, err = ping()

if not ok then
  io.stderr:write("MongoDB ping failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
