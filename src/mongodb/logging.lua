local errors = require("mongodb.error")

local M = {}

local COMPONENTS = {
  command = "MONGODB_LOG_COMMAND",
  connection = "MONGODB_LOG_CONNECTION",
  server_selection = "MONGODB_LOG_SERVER_SELECTION",
  topology = "MONGODB_LOG_TOPOLOGY",
}
local COMPONENT_ORDER = {
  "command",
  "connection",
  "server_selection",
  "topology",
}
local LEVEL_CODES = {
  alert = 1,
  critical = 2,
  debug = 7,
  emergency = 0,
  error = 3,
  info = 6,
  notice = 5,
  off = -1,
  trace = 8,
  warn = 4,
}
local DEFAULT_MAX_DOCUMENT_LENGTH = 1000
local LOGGER_STATES = setmetatable({}, { __mode = "k" })
local LOGGER_METHODS = {}
local LOGGER_METATABLE = {
  __index = function(logger, key)
    return LOGGER_METHODS[key] or LOGGER_STATES[logger][key]
  end,
  __metatable = "mongodb.logging",
  __newindex = function()
    error("logging configuration is immutable", 2)
  end,
}

local function config_error(option, message)
  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    details = { option = option },
    message = message,
  })
end

local function level_code(value)
  if type(value) ~= "string" then
    return nil
  end

  return LEVEL_CODES[string.lower(value)]
end

local function normalize_levels(value)
  if type(value) ~= "table" then
    return config_error("logging.levels", "logging levels must be a table")
  end

  local result = {}

  for component, level in pairs(value) do
    if component ~= "all" and COMPONENTS[component] == nil then
      return config_error(
        "logging.levels." .. tostring(component),
        "unsupported logging component"
      )
    end

    local code = level_code(level)

    if code == nil then
      return config_error(
        "logging.levels." .. component,
        "logging level is not supported"
      )
    end

    result[component] = string.lower(level)
  end

  return result
end

function M.normalize(options)
  if options == nil then
    return {}
  end

  if type(options) ~= "table" then
    return config_error("logging", "logging configuration must be a table")
  end

  local allowed = {
    destination = true,
    levels = true,
    max_document_length = true,
    sink = true,
  }

  for key in pairs(options) do
    if not allowed[key] then
      return config_error("logging." .. tostring(key), "unsupported logging option")
    end
  end

  local result = {}

  if options.levels ~= nil then
    local levels, err = normalize_levels(options.levels)

    if not levels then
      return nil, err
    end

    result.levels = levels
  end

  if options.destination ~= nil then
    if type(options.destination) ~= "string" then
      return config_error(
        "logging.destination",
        "logging destination must be 'stdout' or 'stderr'"
      )
    end

    local destination = string.lower(options.destination)

    if destination ~= "stdout" and destination ~= "stderr" then
      return config_error(
        "logging.destination",
        "logging destination must be 'stdout' or 'stderr'"
      )
    end

    result.destination = destination
  end

  if options.max_document_length ~= nil then
    if math.type(options.max_document_length) ~= "integer"
        or options.max_document_length < 0
    then
      return config_error(
        "logging.max_document_length",
        "logging max_document_length must be a non-negative integer"
      )
    end

    result.max_document_length = options.max_document_length
  end

  if options.sink ~= nil then
    if type(options.sink) ~= "function" then
      return config_error("logging.sink", "logging sink must be a function")
    end

    if result.destination ~= nil then
      return config_error(
        "logging",
        "logging sink and destination cannot both be specified"
      )
    end

    result.sink = options.sink
  end

  return result
end

local function environment_level(runtime, name)
  local value = runtime.environment:get(name)
  local code = level_code(value)

  if code == nil then
    return nil
  end

  return string.lower(value)
end

local function environment_max_document_length(runtime)
  local value = runtime.environment:get("MONGODB_LOG_MAX_DOCUMENT_LENGTH")

  if type(value) ~= "string" or not value:match("^%d+$") then
    return DEFAULT_MAX_DOCUMENT_LENGTH
  end

  local number = tonumber(value)

  if math.type(number) ~= "integer" or number < 0 then
    return DEFAULT_MAX_DOCUMENT_LENGTH
  end

  return number
end

local function environment_destination(runtime)
  local value = runtime.environment:get("MONGODB_LOG_PATH")

  if type(value) == "string" then
    value = string.lower(value)

    if value == "stdout" or value == "stderr" then
      return value
    end
  end

  return "stderr"
end

function LOGGER_METHODS:enabled(component, level)
  if COMPONENTS[component] == nil then
    error("unknown logging component: " .. tostring(component), 2)
  end

  local code = level_code(level)

  if code == nil then
    error("unknown logging level: " .. tostring(level), 2)
  end

  local configured = LOGGER_STATES[self].levels[component]

  return configured >= 0 and code >= 0 and code <= configured
end

function LOGGER_METHODS:output(value)
  local state = LOGGER_STATES[self]

  if state.sink ~= nil then
    return state.sink(value)
  end

  if type(value) ~= "string" then
    error("default logging output requires a string", 2)
  end

  return state.runtime.output:write(state.destination, value)
end

function M.new(runtime, options)
  if type(runtime) ~= "table"
      or type(runtime.environment) ~= "table"
      or type(runtime.environment.get) ~= "function"
      or type(runtime.output) ~= "table"
      or type(runtime.output.write) ~= "function"
  then
    error("logging requires runtime environment and output capabilities", 2)
  end

  local normalized, err = M.normalize(options)

  if not normalized then
    return nil, err
  end

  local all_level = environment_level(runtime, "MONGODB_LOG_ALL") or "off"
  local levels = {}

  for _, component in ipairs(COMPONENT_ORDER) do
    levels[component] = environment_level(runtime, COMPONENTS[component]) or all_level
  end

  for component, level in pairs(normalized.levels or {}) do
    if component == "all" then
      for _, name in ipairs(COMPONENT_ORDER) do
        levels[name] = level
      end
    end
  end

  for component, level in pairs(normalized.levels or {}) do
    if component ~= "all" then
      levels[component] = level
    end
  end

  for component, level in pairs(levels) do
    levels[component] = assert(level_code(level))
  end

  local logger = {}

  LOGGER_STATES[logger] = {
    destination = normalized.sink and "custom"
      or normalized.destination or environment_destination(runtime),
    levels = levels,
    max_document_length = normalized.max_document_length
      or environment_max_document_length(runtime),
    runtime = runtime,
    sink = normalized.sink,
  }

  return setmetatable(logger, LOGGER_METATABLE)
end

return M
