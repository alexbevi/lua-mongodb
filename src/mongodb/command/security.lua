local bson = require("mongodb.bson")

local M = {}

local SENSITIVE_COMMANDS = {
  authenticate = true,
  copydb = true,
  copydbgetnonce = true,
  copydbsaslstart = true,
  createuser = true,
  getnonce = true,
  saslcontinue = true,
  saslstart = true,
  updateuser = true,
}

function M.is_always_sensitive(command_name)
  return type(command_name) == "string"
    and SENSITIVE_COMMANDS[command_name:lower()] == true
end

function M.is_sensitive(command_name, command)
  if M.is_always_sensitive(command_name) then
    return true
  end

  if type(command_name) ~= "string" or not bson.is_document(command) then
    return false
  end

  local lower_name = command_name:lower()

  return (lower_name == "hello" or lower_name == "ismaster")
    and command:get("speculativeAuthenticate") ~= nil
end

function M.redact_server_response(response)
  if not bson.is_document(response) then
    return bson.document({})
  end

  local entries = {}

  for _, name in ipairs({ "code", "codeName", "errorLabels" }) do
    local value = response:get(name)

    if value ~= nil then
      entries[#entries + 1] = { name, value }
    end
  end

  return bson.document(entries)
end

return M
