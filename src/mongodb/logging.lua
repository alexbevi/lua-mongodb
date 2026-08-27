local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local COMPONENTS = {
  command = "MONGODB_LOG_COMMAND",
  connection = "MONGODB_LOG_CONNECTION",
  server_selection = "MONGODB_LOG_SERVER_SELECTION",
  topology = "MONGODB_LOG_TOPOLOGY",
}
local COMPONENT_NAMES = {
  command = "command",
  connection = "connection",
  server_selection = "serverSelection",
  topology = "topology",
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

local function readonly_map(values)
  return setmetatable({}, {
    __index = values,
    __metatable = "mongodb.logging.event.data",
    __newindex = function()
      error("structured log events are immutable", 2)
    end,
    __pairs = function()
      return next, values, nil
    end,
  })
end

local function readonly_event(component, level, data)
  local values = {
    component = component,
    data = readonly_map(data),
    level = level,
  }

  return setmetatable({}, {
    __index = values,
    __metatable = "mongodb.logging.event",
    __newindex = function()
      error("structured log events are immutable", 2)
    end,
    __pairs = function()
      return next, values, nil
    end,
  })
end

local function truncate_document(text, maximum)
  local length = utf8.len(text)

  if length == nil then
    error("rendered log document contains invalid UTF-8", 2)
  end

  if length <= maximum then
    return text
  end

  if maximum == 0 then
    return "..."
  end

  local offset = assert(utf8.offset(text, maximum + 1))

  return text:sub(1, offset - 1) .. "..."
end

local function render_document(value, redacted, maximum)
  if redacted then
    value = bson.document({})
  elseif not bson.is_document(value) then
    error("structured log document fields must be BSON documents", 2)
  end

  local encoded, err = bson.json.encode(value, { mode = "relaxed" })

  if not encoded then
    error(tostring(err), 2)
  end

  return truncate_document(encoded, maximum)
end

local function render_data(fields, options, maximum)
  if type(fields) ~= "table" then
    error("structured log fields must be a table", 2)
  end

  options = options or {}

  if type(options) ~= "table" then
    error("structured log rendering options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "document_fields" then
      error("unknown structured log rendering option", 2)
    end
  end

  local document_fields = options.document_fields or {}

  if type(document_fields) ~= "table" then
    error("structured log document_fields must be a table", 2)
  end

  local rendered = {}

  for field, value in pairs(fields) do
    if type(field) ~= "string" or field == "" then
      error("structured log field names must be non-empty strings", 2)
    end

    if value ~= nil then
      local redacted = document_fields[field]

      if redacted ~= nil then
        if type(redacted) ~= "boolean" then
          error("structured log document redaction flags must be boolean", 2)
        end

        value = render_document(value, redacted, maximum)
      elseif errors.is(value) then
        value = tostring(value)
      end

      rendered[field] = value
    end
  end

  for field, redacted in pairs(document_fields) do
    if type(field) ~= "string" or type(redacted) ~= "boolean" then
      error("structured log document fields must map names to booleans", 2)
    end
  end

  return rendered
end

local function ordered_document(values)
  local keys = {}

  for key in pairs(values) do
    keys[#keys + 1] = key
  end

  table.sort(keys)
  local entries = {}

  for index, key in ipairs(keys) do
    entries[index] = { key, values[key] }
  end

  return bson.document(entries)
end

local function encode_event(event)
  local encoded, err = bson.json.encode(bson.document({
    { "component", event.component },
    { "level", event.level },
    { "data", ordered_document(event.data) },
  }), { mode = "relaxed" })

  if not encoded then
    error(tostring(err), 2)
  end

  return encoded
end

local function deliver_event(state, event)
  if state.sink ~= nil then
    return pcall(state.sink, event)
  end

  local encoded = encode_event(event)
  local ok, written = pcall(
    state.runtime.output.write,
    state.runtime.output,
    state.destination,
    encoded
  )

  return ok and written ~= nil and written ~= false
end

function LOGGER_METHODS:emit(component, level, fields, options)
  local enabled_ok, enabled = pcall(LOGGER_METHODS.enabled, self, component, level)

  if not enabled_ok or not enabled then
    return false
  end

  local state = LOGGER_STATES[self]
  local ok, emitted = pcall(function()
    local rendered = render_data(fields, options, state.max_document_length)
    local event = readonly_event(
      COMPONENT_NAMES[component],
      string.lower(level),
      rendered
    )

    return deliver_event(state, event)
  end)

  return ok and emitted == true
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
