local mongodb = require("mongodb")

local bson = mongodb.bson
local doc = bson.document
local array = bson.array
local int64 = bson.int64
local M = {}

function M.all()
  return {
    doc({
      { "player_id", "player-ada" },
      { "display_name", "Ada Byte" },
      { "high_score", int64(980) },
      { "current_season", "spring-2026" },
      { "season_score", int64(2400) },
      { "credits", int64(120) },
      { "achievements", array({ "first-match" }) },
      { "recent_matches", array({
        doc({ { "score", int64(980) }, { "result", "win" } }),
      }) },
      { "updated_at", "2026-08-18T18:00:00Z" },
    }),
    doc({
      { "player_id", "player-lin" },
      { "display_name", "Lin Loop" },
      { "high_score", int64(1250) },
      { "current_season", "spring-2026" },
      { "season_score", int64(4100) },
      { "credits", int64(80) },
      { "achievements", array({ "hot-streak" }) },
      { "recent_matches", array({
        doc({ { "score", int64(1250) }, { "result", "win" } }),
      }) },
      { "updated_at", "2026-08-18T18:00:00Z" },
    }),
    doc({
      { "player_id", "player-noor" },
      { "display_name", "Noor Node" },
      { "high_score", int64(1110) },
      { "current_season", "spring-2026" },
      { "season_score", int64(3650) },
      { "credits", int64(95) },
      { "achievements", array({ "collector" }) },
      { "recent_matches", array({
        doc({ { "score", int64(1110) }, { "result", "win" } }),
      }) },
      { "updated_at", "2026-08-18T18:00:00Z" },
    }),
    doc({
      { "player_id", "player-ravi" },
      { "display_name", "Ravi Render" },
      { "high_score", int64(875) },
      { "current_season", "spring-2026" },
      { "season_score", int64(2200) },
      { "credits", int64(110) },
      { "achievements", array({}) },
      { "recent_matches", array({
        doc({ { "score", int64(875) }, { "result", "loss" } }),
      }) },
      { "updated_at", "2026-08-18T18:00:00Z" },
    }),
    doc({
      { "player_id", "player-mei" },
      { "display_name", "Mei Mutex" },
      { "high_score", int64(1040) },
      { "current_season", "spring-2026" },
      { "season_score", int64(3300) },
      { "credits", int64(75) },
      { "achievements", array({ "first-match" }) },
      { "recent_matches", array({
        doc({ { "score", int64(1040) }, { "result", "win" } }),
      }) },
      { "updated_at", "2026-08-18T18:00:00Z" },
    }),
  }
end

return M
