local mongodb = require("mongodb")
local packages = require("packages")

local doc = mongodb.bson.document

local function seed()
  local uri = os.getenv("MONGODB_URI")
    or "mongodb://127.0.0.1:27018/lua_examples_packages"

  return mongodb.run(function()
    local client, err = mongodb.client(uri, { app_name = "luarocks-explorer-seed" })

    if not client then
      return nil, err
    end

    local collection = client:database():collection("packages")
    local deleted
    deleted, err = collection:delete_many(doc({}))

    if not deleted then
      client:close()
      return nil, err
    end

    local index_name
    index_name, err = collection:create_index(doc({ { "name", 1 } }), {
      name = "package_name_unique",
      unique = true,
    })

    if not index_name then
      client:close()
      return nil, err
    end

    local inserted
    inserted, err = collection:insert_many(packages.all())

    if not inserted then
      client:close()
      return nil, err
    end

    local closed
    closed, err = client:close()

    if not closed then
      return nil, err
    end

    print("Created unique index: " .. index_name)
    print("Seeded " .. inserted.inserted_count .. " packages")
    return true
  end)
end

local ok, err = seed()

if not ok then
  io.stderr:write("Package seed failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
