local runtime_guard = require("mongodb.runtime_guard")
local handshake_metadata = require("mongodb.handshake.metadata")

local ok, message = runtime_guard.check(_VERSION, math.maxinteger)

if not ok then
  error(message, 2)
end

local M = {
  _VERSION = handshake_metadata.driver_version(),
  bson = require("mongodb.bson"),
  bulk = require("mongodb.bulk"),
  client = require("mongodb.client").connect,
  error = require("mongodb.error"),
  pool = require("mongodb.pool"),
  runtime = require("mongodb.runtime"),
  sdam = require("mongodb.sdam"),
  selection = require("mongodb.selection"),
  topology = require("mongodb.topology"),
}

M.index_model = require("mongodb.admin").index_model

return M
