local mongodb = require("mongodb")

local doc = mongodb.bson.document

local function list_packages()
  local uri = os.getenv("MONGODB_URI")
    or "mongodb://127.0.0.1:27018/lua_examples_packages"

  return mongodb.run(function()
    local client, err = mongodb.client(uri, { app_name = "luarocks-explorer" })

    if not client then
      return nil, err
    end

    local collection = client:database():collection("packages")
    local cursor
    cursor, err = collection:find(doc({}), {
      sort = doc({ { "name", 1 } }),
    })

    if not cursor then
      client:close()
      return nil, err
    end

    local lines = {}

    while true do
      local package_doc
      package_doc, err = cursor:next()

      if not package_doc then
        break
      end

      lines[#lines + 1] = package_doc:get("name")
        .. " — " .. package_doc:get("latest_release")
    end

    if err then
      cursor:close()
      client:close()
      return nil, err
    end

    if not cursor:is_closed() then
      local closed
      closed, err = cursor:close()

      if not closed then
        client:close()
        return nil, err
      end
    end

    local closed
    closed, err = client:close()

    if not closed then
      return nil, err
    end

    print("LuaRocks package catalog (" .. #lines .. " packages)")

    for index, line in ipairs(lines) do
      print(index .. ". " .. line)
    end

    return true
  end)
end

local ok, err = list_packages()

if not ok then
  io.stderr:write("Package listing failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
