local mongodb = require("mongodb")

local bson = mongodb.bson
local doc = bson.document
local int64 = bson.int64
local M = {}

function M.initial()
  return doc({
    { "_id", "demo-match" },
    { "status", "playing" },
    { "players", doc({
      { "p1", doc({
        { "paddle_y", int64(240) },
        { "input_seq", int64(0) },
      }) },
      { "p2", doc({
        { "paddle_y", int64(240) },
        { "input_seq", int64(0) },
      }) },
    }) },
    { "ball", doc({
      { "x", int64(400) },
      { "y", int64(300) },
      { "vx", int64(260) },
      { "vy", int64(160) },
    }) },
    { "score", doc({
      { "p1", int64(0) },
      { "p2", int64(0) },
    }) },
  })
end

return M
