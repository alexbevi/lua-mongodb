local mongodb = require("mongodb")

local bson = mongodb.bson
local doc = bson.document
local array = bson.array
local int64 = bson.int64

local function fail(client, err)
  client:close()
  return nil, err
end

local function transaction_error(message)
  return mongodb.error.new({
    category = mongodb.error.CATEGORY.WRITE,
    message = message,
  })
end

local function transfer_credits(client, collection)
  local session, err = client:start_session()

  if not session then
    return nil, err
  end

  local transferred
  transferred, err = session:with_transaction(function(active_session)
    local debited, debit_err = collection:update_one(
      doc({
        { "player_id", "player-ada" },
        { "credits", doc({ { "$gte", int64(25) } }) },
      }),
      doc({ { "$inc", doc({ { "credits", int64(-25) } }) } }),
      { session = active_session }
    )

    if not debited then
      return nil, debit_err
    end

    if debited.matched_count ~= 1 then
      return nil, transaction_error("player-ada has insufficient credits")
    end

    local credited, credit_err = collection:update_one(
      doc({ { "player_id", "player-lin" } }),
      doc({ { "$inc", doc({ { "credits", int64(25) } }) } }),
      { session = active_session }
    )

    if not credited then
      return nil, credit_err
    end

    if credited.matched_count ~= 1 then
      return nil, transaction_error("player-lin fixture is missing")
    end

    return true
  end, {
    read_concern = doc({ { "level", "snapshot" } }),
    write_concern = doc({ { "w", "majority" } }),
  })

  local ended, end_err = session:end_session()

  if not ended then
    return nil, end_err
  end

  if not transferred then
    return nil, err
  end

  return true
end

local function run_leaderboard()
  local uri = os.getenv("MONGODB_URI")
    or "mongodb://127.0.0.1:27019/lua_examples_leaderboard?replicaSet=rs0"

  return mongodb.run(function()
    local client, err = mongodb.client(uri, { app_name = "leaderboard-backend" })

    if not client then
      return nil, err
    end

    local collection = client:database():collection("players")
    local submitted
    submitted, err = collection:update_one(
      doc({ { "player_id", "player-ada" } }),
      doc({
        { "$max", doc({ { "high_score", int64(1320) } }) },
        { "$inc", doc({ { "season_score", int64(1320) } }) },
        { "$push", doc({
          { "recent_matches", doc({
            { "score", int64(1320) },
            { "result", "win" },
          }) },
        }) },
        { "$set", doc({ { "updated_at", "2026-08-18T19:00:00Z" } }) },
      })
    )

    if not submitted then
      return fail(client, err)
    end

    local awarded
    awarded, err = collection:update_one(
      doc({ { "player_id", "player-ada" } }),
      doc({
        { "$addToSet", doc({ { "achievements", "comeback" } }) },
      })
    )

    if not awarded then
      return fail(client, err)
    end

    local ada
    ada, err = collection:find_one(doc({ { "player_id", "player-ada" } }))

    if not ada then
      return fail(client, err or "player-ada fixture is missing")
    end

    local cursor
    cursor, err = collection:find(doc({
      { "current_season", "spring-2026" },
    }), {
      sort = doc({ { "high_score", -1 }, { "display_name", 1 } }),
      limit = 3,
    })

    if not cursor then
      return fail(client, err)
    end

    local ranking = {}

    while true do
      local player
      player, err = cursor:next()

      if not player then
        break
      end

      ranking[#ranking + 1] = player:get("display_name") .. ": "
        .. player:get("high_score"):to_number()
    end

    if err then
      return fail(client, err)
    end

    cursor, err = collection:aggregate(array({
      doc({ { "$match", doc({
        { "current_season", "spring-2026" },
      }) } }),
      doc({ { "$group", doc({
        { "_id", "$current_season" },
        { "total_score", doc({ { "$sum", "$season_score" } }) },
        { "player_count", doc({ { "$sum", 1 } }) },
      }) } }),
    }))

    if not cursor then
      return fail(client, err)
    end

    local season_rows = {}

    while true do
      local season
      season, err = cursor:next()

      if not season then
        break
      end

      season_rows[#season_rows + 1] = season
    end

    if err then
      return fail(client, err)
    end

    local season = season_rows[1]

    if not season then
      return fail(client, "season aggregation returned no results")
    end

    local transferred
    transferred, err = transfer_credits(client, collection)

    if not transferred then
      return fail(client, err)
    end

    local ada_after
    ada_after, err = collection:find_one(doc({ { "player_id", "player-ada" } }))

    if not ada_after then
      return fail(client, err or "player-ada fixture is missing after transfer")
    end

    local lin_after
    lin_after, err = collection:find_one(doc({ { "player_id", "player-lin" } }))

    if not lin_after then
      return fail(client, err or "player-lin fixture is missing after transfer")
    end

    local closed
    closed, err = client:close()

    if not closed then
      return nil, err
    end

    print("Submitted 1320 points for " .. ada:get("display_name")
      .. " (" .. submitted.modified_count .. " modified)")
    print("Awarded comeback achievement to " .. ada:get("display_name")
      .. " (" .. awarded.modified_count .. " modified)")
    print("Top players:")

    for index, line in ipairs(ranking) do
      print(index .. ". " .. line)
    end

    print("Season " .. season:get("_id") .. ": "
      .. season:get("total_score"):to_number() .. " points across "
      .. season:get("player_count"):to_number() .. " players")
    print("Transferred 25 credits: " .. ada_after:get("display_name") .. " "
      .. ada_after:get("credits"):to_number() .. ", "
      .. lin_after:get("display_name") .. " "
      .. lin_after:get("credits"):to_number())

    return true
  end)
end

local ok, err = run_leaderboard()

if not ok then
  io.stderr:write("Leaderboard failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
