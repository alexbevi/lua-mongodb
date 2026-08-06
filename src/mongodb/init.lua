local runtime_guard = require("mongodb.runtime_guard")

local ok, message = runtime_guard.check(_VERSION, math.maxinteger)

if not ok then
  error(message, 2)
end

local M = {
  _VERSION = "0.1.0-dev",
  bson = require("mongodb.bson"),
  bulk = require("mongodb.bulk"),
  client = require("mongodb.client").connect,
  error = require("mongodb.error"),
  runtime = require("mongodb.runtime"),
  sdam = require("mongodb.sdam"),
  selection = require("mongodb.selection"),
}

M.index_model = require("mongodb.admin").index_model

return M
