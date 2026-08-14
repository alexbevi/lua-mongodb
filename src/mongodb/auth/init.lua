local plain = require("mongodb.auth.plain")
local scram = require("mongodb.auth.scram")

local M = {}

function M.authenticate(commands, runtime, credentials, options)
  if type(credentials) ~= "table" then
    error("authentication credentials must be a table", 2)
  end

  if options ~= nil and type(options) ~= "table" then
    error("authentication options must be a table", 2)
  end

  local mechanism = options and options.mechanism or credentials.mechanism

  if mechanism == "PLAIN" then
    return plain.authenticate(commands, credentials, options)
  end

  return scram.authenticate(commands, runtime, credentials, options)
end

return M
