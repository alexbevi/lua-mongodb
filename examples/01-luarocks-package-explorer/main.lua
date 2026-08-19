local mongodb = require("mongodb")

local bson = mongodb.bson
local doc = bson.document
local array = bson.array

local function collect(cursor, transform)
  local values = {}

  while true do
    local value, err = cursor:next()

    if err then
      if not cursor:is_closed() then
        cursor:close()
      end

      return nil, err
    end

    if not value then
      break
    end

    values[#values + 1] = transform(value)
  end

  if not cursor:is_closed() then
    local closed, err = cursor:close()

    if not closed then
      return nil, err
    end
  end

  return values
end

local function fail(client, err)
  client:close()
  return nil, err
end

local function explore_packages()
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
      return fail(client, err)
    end

    local package_lines
    package_lines, err = collect(cursor, function(package_doc)
      return package_doc:get("name")
        .. " — " .. package_doc:get("latest_release")
    end)

    if not package_lines then
      return fail(client, err)
    end

    local copas
    copas, err = collection:find_one(doc({ { "name", "copas" } }))

    if not copas then
      return fail(client, err or "copas fixture is missing")
    end

    local nested_release
    nested_release, err = collection:find_one(doc({
      { "versions.version", "1.3.2-1" },
    }))

    if not nested_release then
      return fail(client, err or "nested release fixture is missing")
    end

    cursor, err = collection:find(doc({ { "labels", "networking" } }), {
      sort = doc({ { "name", 1 } }),
    })

    if not cursor then
      return fail(client, err)
    end

    local networking_packages
    networking_packages, err = collect(cursor, function(package_doc)
      return package_doc:get("name")
    end)

    if not networking_packages then
      return fail(client, err)
    end

    local old_release = copas:get("latest_release")
    local new_release = "4.11.1-1"
    local updated
    updated, err = collection:update_one(
      doc({ { "name", "copas" } }),
      doc({
        { "$set", doc({ { "latest_release", new_release } }) },
        { "$push", doc({
          { "versions", doc({
            { "version", new_release },
            { "released", "2025-03-07" },
          }) },
        }) },
      })
    )

    if not updated then
      return fail(client, err)
    end

    cursor, err = collection:aggregate(array({
      doc({ { "$unwind", "$dependencies" } }),
      doc({ { "$group", doc({
        { "_id", "$dependencies" },
        { "dependency_count", doc({ { "$sum", 1 } }) },
      }) } }),
      doc({ { "$sort", doc({
        { "dependency_count", -1 },
        { "_id", 1 },
      }) } }),
    }))

    if not cursor then
      return fail(client, err)
    end

    local dependency_lines
    dependency_lines, err = collect(cursor, function(dependency)
      local count = dependency:get("dependency_count"):to_number()
      local noun = count == 1 and "package" or "packages"

      return dependency:get("_id") .. " — " .. count .. " " .. noun
    end)

    if not dependency_lines then
      return fail(client, err)
    end

    local closed
    closed, err = client:close()

    if not closed then
      return nil, err
    end

    print("LuaRocks package catalog (" .. #package_lines .. " packages)")

    for index, line in ipairs(package_lines) do
      print(index .. ". " .. line)
    end

    print("Lookup: " .. copas:get("name") .. " — " .. copas:get("summary"))
    print("Nested release query: " .. nested_release:get("name")
      .. " contains 1.3.2-1")
    print("Networking label: " .. table.concat(networking_packages, ", "))
    print("Updated copas: " .. old_release .. " -> " .. new_release
      .. " (" .. updated.modified_count .. " modified)")
    print("Dependency popularity:")

    for index, line in ipairs(dependency_lines) do
      print(index .. ". " .. line)
    end

    return true
  end)
end

local ok, err = explore_packages()

if not ok then
  io.stderr:write("Package explorer failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
