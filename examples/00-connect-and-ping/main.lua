local mongodb = require("mongodb")

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

    print("Ping succeeded")
    print("Client closed")
    return true
  end)
end

local ok, err = ping()

if not ok then
  io.stderr:write("MongoDB ping failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
