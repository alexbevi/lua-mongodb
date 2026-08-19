local mongodb = require("mongodb")
local players = require("players")

local doc = mongodb.bson.document

local function seed()
  local uri = os.getenv("MONGODB_URI")
    or "mongodb://127.0.0.1:27019/lua_examples_leaderboard?replicaSet=rs0"

  return mongodb.run(function()
    local client, err = mongodb.client(uri, { app_name = "leaderboard-seed" })

    if not client then
      return nil, err
    end

    local collection = client:database():collection("players")
    local deleted
    deleted, err = collection:delete_many(doc({}))

    if not deleted then
      client:close()
      return nil, err
    end

    local index_name
    index_name, err = collection:create_index(doc({ { "player_id", 1 } }), {
      name = "player_id_unique",
      unique = true,
    })

    if not index_name then
      client:close()
      return nil, err
    end

    local inserted
    inserted, err = collection:insert_many(players.all())

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
    print("Seeded " .. inserted.inserted_count .. " players")
    return true
  end)
end

local ok, err = seed()

if not ok then
  io.stderr:write("Leaderboard seed failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
