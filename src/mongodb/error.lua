local M = {}

local ERROR_STATES = setmetatable({}, { __mode = "k" })

local function immutable_value()
  error("structured error values are immutable", 2)
end

local function readonly_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end

  local protected_type = getmetatable(value)

  if protected_type == "mongodb.bson.document"
    or protected_type == "mongodb.bson.array"
    or protected_type == "mongodb.bson.binary"
    or protected_type == "mongodb.bson.int32"
    or protected_type == "mongodb.bson.int64"
    or protected_type == "mongodb.bson.double"
    or protected_type == "mongodb.error"
    or protected_type == "mongodb.client_bulk.result"
    or protected_type == "mongodb.client_bulk.result_map"
  then
    return value
  end

  seen = seen or {}

  if seen[value] then
    return seen[value]
  end

  local data = {}
  local proxy = {}

  seen[value] = proxy

  for key, item in pairs(value) do
    data[key] = readonly_copy(item, seen)
  end

  setmetatable(proxy, {
    __index = data,
    __len = function()
      return #data
    end,
    __newindex = immutable_value,
    __pairs = function()
      return next, data, nil
    end,
    __metatable = "mongodb.readonly",
  })

  return proxy
end

local CATEGORY_VALUES = {
  AUTHENTICATION = "authentication",
  BSON = "bson",
  CANCELLED = "cancelled",
  CLIENT = "client",
  CONFIGURATION = "configuration",
  INTERNAL = "internal",
  NETWORK = "network",
  POOL = "pool",
  PROTOCOL = "protocol",
  SERVER = "server",
  SERVER_SELECTION = "server_selection",
  TIMEOUT = "timeout",
  TOPOLOGY = "topology",
  TRANSACTION = "transaction",
  WRITE = "write",
}

local VALID_CATEGORIES = {}

for _, category in pairs(CATEGORY_VALUES) do
  VALID_CATEGORIES[category] = true
end

M.CATEGORY = readonly_copy(CATEGORY_VALUES)

local ALLOWED_OPTIONS = {
  category = true,
  cause = true,
  code = true,
  code_name = true,
  details = true,
  labels = true,
  message = true,
  retryable = true,
  server = true,
  timeout = true,
  topology = true,
}

local METHODS = {}
local ERROR_METATABLE = {}

local function state_for(err)
  return ERROR_STATES[err]
end

local function require_error(err)
  local state = state_for(err)

  if not state then
    error("expected a structured error", 3)
  end

  return state
end

local function require_label(label)
  if type(label) ~= "string" or label == "" then
    error("error label must be a non-empty string", 3)
  end
end

local function copy_labels(labels)
  if labels == nil then
    return {}, {}
  end

  if type(labels) ~= "table" then
    error("labels must be an array of non-empty strings", 3)
  end

  local values = {}
  local label_set = {}
  local length = #labels

  for key in pairs(labels) do
    if math.type(key) ~= "integer" or key < 1 or key > length then
      error("labels must be an array of non-empty strings", 3)
    end
  end

  for index = 1, length do
    local label = labels[index]

    if type(label) ~= "string" or label == "" then
      error("labels must be an array of non-empty strings", 3)
    end

    if not label_set[label] then
      values[#values + 1] = label
      label_set[label] = true
    end
  end

  return values, label_set
end

local function validate_optional_string(name, value)
  if value ~= nil and (type(value) ~= "string" or value == "") then
    error(name .. " must be a non-empty string when provided", 3)
  end
end

local function validate_optional_boolean(name, value)
  if value ~= nil and type(value) ~= "boolean" then
    error(name .. " must be a boolean when provided", 3)
  end
end

function METHODS:has_label(label)
  require_label(label)
  return state_for(self).label_set[label] == true
end

function METHODS:is_category(category)
  return state_for(self).category == category
end

function METHODS:is_timeout()
  return state_for(self).timeout
end

function METHODS:is_retryable()
  return state_for(self).retryable
end

function ERROR_METATABLE.__index(err, key)
  if METHODS[key] then
    return METHODS[key]
  end

  local state = state_for(err)
  return state and state[key] or nil
end

ERROR_METATABLE.__newindex = function()
  error("structured errors are immutable", 2)
end

ERROR_METATABLE.__tostring = function(err)
  local state = state_for(err)
  local value = state.category .. ": " .. state.message

  if state.code ~= nil then
    value = value .. " (code " .. tostring(state.code)

    if state.code_name then
      value = value .. ": " .. state.code_name
    end

    value = value .. ")"
  elseif state.code_name then
    value = value .. " (" .. state.code_name .. ")"
  end

  if state.server then
    value = value .. " [server " .. state.server .. "]"
  end

  return value
end


ERROR_METATABLE.__metatable = "mongodb.error"

function M.new(options)
  if type(options) ~= "table" then
    error("error options must be a table", 2)
  end

  for key in pairs(options) do
    if not ALLOWED_OPTIONS[key] then
      error("unknown error option: " .. tostring(key), 2)
    end
  end

  if not VALID_CATEGORIES[options.category] then
    error("category must be a known error category", 2)
  end

  if type(options.message) ~= "string" or options.message == "" then
    error("message must be a non-empty string", 2)
  end

  if options.code ~= nil and math.type(options.code) ~= "integer" then
    error("code must be an integer when provided", 2)
  end

  validate_optional_string("code_name", options.code_name)
  validate_optional_string("server", options.server)
  validate_optional_string("topology", options.topology)
  validate_optional_boolean("retryable", options.retryable)
  validate_optional_boolean("timeout", options.timeout)

  if options.cause ~= nil and not ERROR_STATES[options.cause] then
    error("cause must be a structured error", 2)
  end

  if options.details ~= nil and type(options.details) ~= "table" then
    error("details must be a table when provided", 2)
  end

  local label_values, label_set = copy_labels(options.labels)
  local cause_timeout = options.cause and options.cause.timeout or false
  local err = {}

  ERROR_STATES[err] = {
    category = options.category,
    cause = options.cause,
    code = options.code,
    code_name = options.code_name,
    details = options.details and readonly_copy(options.details) or nil,
    label_set = label_set,
    label_values = label_values,
    labels = readonly_copy(label_values),
    message = options.message,
    retryable = options.retryable == true,
    server = options.server,
    timeout = options.category == CATEGORY_VALUES.TIMEOUT
      or options.timeout == true
      or cause_timeout,
    topology = options.topology,
  }

  return setmetatable(err, ERROR_METATABLE)
end

function M.is(value, category)
  local state = state_for(value)

  if not state then
    return false
  end

  return category == nil or state.category == category
end

function M.has_label(value, label)
  local state = state_for(value)

  if not state then
    return false
  end

  require_label(label)
  return state.label_set[label] == true
end

local function copy_options(state, labels)
  return {
    category = state.category,
    cause = state.cause,
    code = state.code,
    code_name = state.code_name,
    details = state.details,
    labels = labels,
    message = state.message,
    retryable = state.retryable,
    server = state.server,
    timeout = state.timeout,
    topology = state.topology,
  }
end

function M.with_label(err, label)
  local state = require_error(err)
  require_label(label)

  if state.label_set[label] then
    return err
  end

  local labels = {}

  for index, existing in ipairs(state.label_values) do
    labels[index] = existing
  end

  labels[#labels + 1] = label
  return M.new(copy_options(state, labels))
end

function M.without_label(err, label)
  local state = require_error(err)
  require_label(label)

  if not state.label_set[label] then
    return err
  end

  local labels = {}

  for _, existing in ipairs(state.label_values) do
    if existing ~= label then
      labels[#labels + 1] = existing
    end
  end

  return M.new(copy_options(state, labels))
end

return M
