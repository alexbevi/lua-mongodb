local mongodb = require("mongodb")
local match = require("match")

local doc = mongodb.bson.document

local function seed()
  local uri = os.getenv("MONGODB_URI")
    or "mongodb://127.0.0.1:27020/pong_demo?replicaSet=rs0"

  return mongodb.run(function()
    local client, err = mongodb.client(uri, { app_name = "pong-seed" })

    if not client then
      return nil, err
    end

    local collection = client:database():collection("matches")
    local deleted
    deleted, err = collection:delete_one(doc({ { "_id", "demo-match" } }))

    if not deleted then
      client:close()
      return nil, err
    end

    local inserted
    inserted, err = collection:insert_one(match.initial())

    if not inserted then
      client:close()
      return nil, err
    end

    local closed
    closed, err = client:close()

    if not closed then
      return nil, err
    end

    print("Seeded match: " .. inserted.inserted_id)
    return true
  end)
end

local ok, err = seed()

if not ok then
  io.stderr:write("Pong seed failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
