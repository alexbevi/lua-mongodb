local mongodb = require("mongodb")

local bson = mongodb.bson
local doc = bson.document
local array = bson.array
local int64 = bson.int64

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

    local ranking
    ranking, err = collect(cursor, function(player)
      return player:get("display_name") .. " — "
        .. player:get("high_score"):to_number()
    end)

    if not ranking then
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

    local season_rows
    season_rows, err = collect(cursor, function(season)
      return {
        name = season:get("_id"),
        total_score = season:get("total_score"):to_number(),
        player_count = season:get("player_count"):to_number(),
      }
    end)

    if not season_rows then
      return fail(client, err)
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

    local season = season_rows[1]
    print("Season " .. season.name .. ": " .. season.total_score
      .. " points across " .. season.player_count .. " players")

    return true
  end)
end

local ok, err = run_leaderboard()

if not ok then
  io.stderr:write("Leaderboard failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
