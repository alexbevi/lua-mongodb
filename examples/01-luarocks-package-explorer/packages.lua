local mongodb = require("mongodb")

local bson = mongodb.bson
local doc = bson.document
local array = bson.array
local M = {}

function M.all()
  return {
    doc({
      { "name", "busted" },
      { "summary", "Behavior-driven testing for Lua" },
      { "uploader", "lunarmodules" },
      { "license", "MIT" },
      { "labels", array({ "testing", "development" }) },
      { "versions", array({
        doc({ { "version", "2.2.0-1" }, { "released", "2024-02-10" } }),
        doc({ { "version", "2.3.0-1" }, { "released", "2025-01-12" } }),
      }) },
      { "dependencies", array({ "lua-term", "penlight" }) },
      { "download_count", bson.int64(2850000) },
      { "latest_release", "2.3.0-1" },
    }),
    doc({
      { "name", "copas" },
      { "summary", "Coroutine-oriented portable asynchronous services" },
      { "uploader", "lunarmodules" },
      { "license", "MIT" },
      { "labels", array({ "networking", "coroutines" }) },
      { "versions", array({
        doc({ { "version", "4.10.0-1" }, { "released", "2023-08-21" } }),
        doc({ { "version", "4.11.0-1" }, { "released", "2024-05-04" } }),
      }) },
      { "dependencies", array({ "luasocket", "coxpcall" }) },
      { "download_count", bson.int64(940000) },
      { "latest_release", "4.11.0-1" },
    }),
    doc({
      { "name", "dkjson" },
      { "summary", "JSON module written in Lua" },
      { "uploader", "luarocks" },
      { "license", "MIT" },
      { "labels", array({ "json", "serialization" }) },
      { "versions", array({
        doc({ { "version", "2.7-1" }, { "released", "2022-06-01" } }),
        doc({ { "version", "2.8-1" }, { "released", "2024-09-17" } }),
      }) },
      { "dependencies", array({}) },
      { "download_count", bson.int64(7600000) },
      { "latest_release", "2.8-1" },
    }),
    doc({
      { "name", "lpeg" },
      { "summary", "Pattern-matching library for Lua" },
      { "uploader", "luarocks" },
      { "license", "MIT" },
      { "labels", array({ "parsing", "patterns" }) },
      { "versions", array({
        doc({ { "version", "1.0.2-1" }, { "released", "2019-06-25" } }),
        doc({ { "version", "1.1.0-2" }, { "released", "2023-09-13" } }),
      }) },
      { "dependencies", array({}) },
      { "download_count", bson.int64(4800000) },
      { "latest_release", "1.1.0-2" },
    }),
    doc({
      { "name", "luacheck" },
      { "summary", "Static analyzer and linter for Lua" },
      { "uploader", "mpeterv" },
      { "license", "MIT" },
      { "labels", array({ "lint", "development" }) },
      { "versions", array({
        doc({ { "version", "1.1.2-1" }, { "released", "2023-03-26" } }),
        doc({ { "version", "1.2.0-1" }, { "released", "2024-07-06" } }),
      }) },
      { "dependencies", array({ "argparse", "luafilesystem" }) },
      { "download_count", bson.int64(3900000) },
      { "latest_release", "1.2.0-1" },
    }),
    doc({
      { "name", "luasec" },
      { "summary", "TLS support for LuaSocket" },
      { "uploader", "lunarmodules" },
      { "license", "MIT" },
      { "labels", array({ "tls", "networking" }) },
      { "versions", array({
        doc({ { "version", "1.3.1-1" }, { "released", "2023-10-02" } }),
        doc({ { "version", "1.3.2-1" }, { "released", "2024-04-11" } }),
      }) },
      { "dependencies", array({ "luasocket" }) },
      { "download_count", bson.int64(2100000) },
      { "latest_release", "1.3.2-1" },
    }),
    doc({
      { "name", "luasocket" },
      { "summary", "Network support for the Lua language" },
      { "uploader", "lunarmodules" },
      { "license", "MIT" },
      { "labels", array({ "networking", "sockets" }) },
      { "versions", array({
        doc({ { "version", "3.0rc1-2" }, { "released", "2020-09-18" } }),
        doc({ { "version", "3.1.0-1" }, { "released", "2022-09-30" } }),
      }) },
      { "dependencies", array({}) },
      { "download_count", bson.int64(5800000) },
      { "latest_release", "3.1.0-1" },
    }),
    doc({
      { "name", "penlight" },
      { "summary", "General-purpose Lua utility libraries" },
      { "uploader", "lunarmodules" },
      { "license", "MIT" },
      { "labels", array({ "utilities", "collections" }) },
      { "versions", array({
        doc({ { "version", "1.13.1-1" }, { "released", "2023-04-16" } }),
        doc({ { "version", "1.14.0-3" }, { "released", "2024-11-08" } }),
      }) },
      { "dependencies", array({ "luafilesystem" }) },
      { "download_count", bson.int64(3200000) },
      { "latest_release", "1.14.0-3" },
    }),
  }
end

return M
