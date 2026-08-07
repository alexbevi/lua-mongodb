local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local function command_options()
  return {
    monitor = false,
    read_preference = { mode = "primary" },
  }
end

local function configuration_error(message, path)
  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    details = { path = path or "$" },
    message = message,
  })
end

local function validate_arguments(arguments, path)
  if not bson.is_document(arguments) then
    return configuration_error("failPoint arguments must be a document", path)
  end

  for key in arguments:iter() do
    if key ~= "client" and key ~= "failPoint" then
      return configuration_error("unsupported failPoint argument: " .. key, path .. "." .. key)
    end
  end

  local client = arguments:get("client")
  local command = arguments:get("failPoint")

  if type(client) ~= "string" or client == "" then
    return configuration_error("failPoint client must be an entity id", path .. ".client")
  end

  if not bson.is_document(command) then
    return configuration_error("failPoint command must be a document", path .. ".failPoint")
  end

  local name = command:get("configureFailPoint")

  if type(name) ~= "string" or name == "" then
    return configuration_error(
      "failPoint command must name configureFailPoint",
      path .. ".failPoint.configureFailPoint"
    )
  end

  return client, command, name
end

local function close_cleanup(close)
  if close == nil then
    return true
  end

  local result = table.pack(pcall(close))

  if not result[1] then
    return nil, result[2]
  end

  return result[2], result[3]
end

local function execute(options, runner, arguments, path)
  local arguments_path = (path or "$.operation") .. ".arguments"
  local client_id, command, name = validate_arguments(arguments, arguments_path)

  if not client_id then
    return nil, command
  end

  local client, err = runner:get_entity(client_id, "client", arguments_path .. ".client")

  if not client then
    return nil, err
  end

  local database
  database, err = client:database("admin")

  if not database then
    return nil, err
  end

  local response
  response, err = database:run_command(command, command_options())

  if not response then
    return nil, err
  end

  local disable = bson.document({
    { "configureFailPoint", name },
    { "mode", "off" },
  })

  runner:add_finalizer(function()
    local cleanup_database = database
    local close

    if options.cleanup_database then
      cleanup_database, close = options.cleanup_database()

      if not cleanup_database then
        return nil, close
      end
    end

    local disabled, disable_err = cleanup_database:run_command(disable, command_options())
    local closed, close_err = close_cleanup(close)

    if not disabled then
      return nil, disable_err
    end

    if not closed then
      return nil, close_err
    end

    return true
  end)
  return true
end

function M.new(options)
  options = options or {}

  if type(options) ~= "table" then
    error("unified failpoint options must be a table", 2)
  end

  if options.cleanup_database ~= nil and type(options.cleanup_database) ~= "function" then
    error("unified failpoint cleanup_database must be a function", 2)
  end

  return function(runner, arguments, path)
    return execute(options, runner, arguments, path)
  end
end

M.execute = M.new()

return M
