local runtime_guard = require("mongodb.runtime_guard")

local ok, message = runtime_guard.check(_VERSION, math.maxinteger)

if not ok then
  error(message, 2)
end

local M = {
  _VERSION = "0.1.0-dev",
  error = require("mongodb.error"),
  runtime = require("mongodb.runtime"),
}

return M
