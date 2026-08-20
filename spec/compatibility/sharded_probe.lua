local ROOT = os.getenv("PWD") or "."

package.path = ROOT .. "/src/?.lua;" .. ROOT .. "/src/?/init.lua;" .. package.path

local copas = require("copas")
local mongodb = require("mongodb")

local uri = arg[1] or os.getenv("MONGODB_COMPATIBILITY_URI")

assert(type(uri) == "string" and uri ~= "", "compatibility probe requires a URI")

local doc = mongodb.bson.document
local outcome
local client

copas.loop(function()
  outcome = table.pack(pcall(function()
    client = assert(mongodb.client(uri, {
      compressors = { "zlib" },
      runtime = mongodb.runtime.copas(),
      server_selection_timeout_ms = 5000,
    }))

    local database_name = "lua_mongodb_compat"
    local database = client:database(database_name)
    local collection = database:collection("items", {
      read_concern = { level = "majority" },
      write_concern = { w = "majority" },
    })
    local hello = assert(database:run_command("hello"))

    assert(hello:get("msg") == "isdbgrid", "compatibility topology is not Sharded")
    assert(client:drop_database(database_name))
    assert(collection:insert_one(doc({ { "_id", 1 }, { "kind", "baseline" } })))
    assert(
      assert(collection:create_index(doc({ { "kind", 1 } }))) == "kind_1",
      "compatibility index name was not preserved"
    )

    local indexes = assert(collection:list_indexes())
    local found_index = false

    for index in indexes:iter() do
      if index:get("name") == "kind_1" then
        found_index = true
      end
    end

    assert(found_index, "compatibility index was not listed")

    local session = assert(client:start_session())

    assert(session:start_transaction({
      read_concern = doc({ { "level", "snapshot" } }),
      write_concern = doc({ { "w", "majority" } }),
    }))
    assert(collection:insert_one(
      doc({ { "_id", 2 }, { "kind", "transaction" } }),
      { session = session }
    ))
    local command_reply = assert(database:run_command(doc({
      { "find", "items" },
      { "filter", doc({ { "_id", 1 } }) },
    }), { session = session }))

    assert(command_reply:get("cursor"), "transaction command did not return a cursor")
    assert(session:commit_transaction())
    assert(collection:find_one(doc({ { "_id", 2 } })))
    assert(session:end_session())
    assert(collection:drop_index("kind_1"))
    assert(client:drop_database(database_name))
    assert(client:close())
  end))

  if client then
    client:close()
  end
end)

if not outcome[1] then
  io.stderr:write("sharded compatibility probe: " .. tostring(outcome[2]) .. "\n")
  os.exit(1)
end

print("sharded compatibility probe: v0.4 public boundaries passed")
