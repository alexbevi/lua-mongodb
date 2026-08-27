local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local COMPONENTS = {
  command = "command",
  connection = "connection",
  serverSelection = "server_selection",
  topology = "topology",
}
local LEVELS = {
  alert = true,
  critical = true,
  debug = true,
  emergency = true,
  error = true,
  info = true,
  notice = true,
  off = true,
  trace = true,
  warn = true,
}

local function configuration_error(message, path, details)
  details = details or {}
  details.path = path or "$"

  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    details = details,
    message = message,
  })
end

local function validate_fields(document, allowed, path)
  for key in document:iter() do
    if not allowed[key] then
      return configuration_error("unsupported unified log field: " .. key, path .. "." .. key)
    end
  end

  return true
end

local COLLECTOR_METHODS = {}
local COLLECTOR_METATABLE = { __index = COLLECTOR_METHODS }

function COLLECTOR_METHODS:disable()
  self.active = false
end

function COLLECTOR_METHODS:options()
  return {
    levels = self.levels,
    max_document_length = 10000,
    sink = function(event)
      if self.active then
        self.messages[#self.messages + 1] = event
      end
    end,
  }
end

function M.new(specification)
  local observed = specification:get("observeLogMessages") or bson.document({})

  if not bson.is_document(observed) then
    return configuration_error(
      "observeLogMessages must be a document",
      "$.client.observeLogMessages"
    )
  end

  local levels = {}

  for component, level in observed:iter() do
    local internal = COMPONENTS[component]

    if not internal then
      return configuration_error(
        "unsupported observed log component: " .. component,
        "$.client.observeLogMessages." .. component
      )
    end

    if type(level) ~= "string" or not LEVELS[level:lower()] then
      return configuration_error(
        "unsupported observed log level: " .. tostring(level),
        "$.client.observeLogMessages." .. component
      )
    end

    levels[internal] = level:lower()
  end

  return setmetatable({
    active = true,
    levels = levels,
    messages = {},
  }, COLLECTOR_METATABLE)
end

local function data_document(data)
  local entries = {}

  for key, value in pairs(data) do
    entries[#entries + 1] = { key, value }
  end

  table.sort(entries, function(left, right)
    return left[1] < right[1]
  end)
  local encoded = assert(bson.encode(bson.document(entries)))

  return assert(bson.decode(encoded))
end

local function validate_expected_message(expected, path)
  if not bson.is_document(expected) then
    return configuration_error("expected log message must be a document", path)
  end

  local valid, err = validate_fields(expected, {
    component = true,
    data = true,
    failureIsRedacted = true,
    level = true,
  }, path)

  if not valid then
    return nil, err
  end

  if type(expected:get("component")) ~= "string" then
    return configuration_error("expected log component must be a string", path .. ".component")
  end

  if type(expected:get("level")) ~= "string" then
    return configuration_error("expected log level must be a string", path .. ".level")
  end

  if not bson.is_document(expected:get("data")) then
    return configuration_error("expected log data must be a document", path .. ".data")
  end

  local failure_is_redacted = expected:get("failureIsRedacted")

  if failure_is_redacted ~= nil and type(failure_is_redacted) ~= "boolean" then
    return configuration_error(
      "failureIsRedacted must be a boolean",
      path .. ".failureIsRedacted"
    )
  end

  return true
end

local function failure_redacted(value)
  if value == "" or value == "{}" or value == "{ }" or bson.is_null(value) then
    return true
  end

  if not bson.is_document(value) then
    return false
  end

  local allowed = {
    code = true,
    codeName = true,
    errorLabels = true,
  }

  for key in value:iter() do
    if not allowed[key] then
      return false
    end
  end

  return true
end

local function match_message(runner, expected, actual, path)
  if expected:get("component") ~= actual.component then
    return configuration_error("log component does not match", path .. ".component")
  end

  if expected:get("level") ~= actual.level then
    return configuration_error("log level does not match", path .. ".level")
  end

  local failure_is_redacted = expected:get("failureIsRedacted")

  if failure_is_redacted ~= nil then
    local failure = actual.data.failure

    if failure == nil then
      return configuration_error("log failure is missing", path .. ".failureIsRedacted")
    end

    if failure_redacted(failure) ~= failure_is_redacted then
      return configuration_error(
        "log failure redaction does not match",
        path .. ".failureIsRedacted"
      )
    end
  end

  return runner:match(expected:get("data"), data_document(actual.data), path .. ".data")
end

local function validate_messages(messages, path)
  if not bson.is_array(messages) then
    return configuration_error("expected log messages must be an array", path)
  end

  for index, expected in messages:iter() do
    local valid, err = validate_expected_message(expected, path .. "[" .. index .. "]")

    if not valid then
      return nil, err
    end
  end

  return true
end

local function retained_messages(runner, actual, ignored, path)
  local retained = {}

  for _, message in ipairs(actual) do
    local discard = false

    for index, expected in ignored:iter() do
      local matched = match_message(
        runner,
        expected,
        message,
        path .. "[" .. index .. "]"
      )

      if matched then
        discard = true
        break
      end
    end

    if not discard then
      retained[#retained + 1] = message
    end
  end

  return retained
end

function M.assert_all(runner, expected_groups, collectors, path)
  path = path or "$.expectLogMessages"

  if not bson.is_array(expected_groups) then
    return configuration_error("expected log groups must be an array", path)
  end

  for _, collector in pairs(collectors) do
    collector:disable()
  end

  for group_index, group in expected_groups:iter() do
    local group_path = path .. "[" .. group_index .. "]"

    if not bson.is_document(group) then
      return configuration_error("expected logs for client must be a document", group_path)
    end

    local valid, err = validate_fields(group, {
      client = true,
      ignoreExtraMessages = true,
      ignoreMessages = true,
      messages = true,
    }, group_path)

    if not valid then
      return nil, err
    end

    local client
    client, err = runner:get_entity(group:get("client"), "client", group_path .. ".client")

    if not client then
      return nil, err
    end

    local collector = collectors[client]

    if not collector then
      return configuration_error("client has no unified log collector", group_path .. ".client")
    end

    local expected = group:get("messages")
    valid, err = validate_messages(expected, group_path .. ".messages")

    if not valid then
      return nil, err
    end

    local ignored = group:get("ignoreMessages") or bson.array({})
    valid, err = validate_messages(ignored, group_path .. ".ignoreMessages")

    if not valid then
      return nil, err
    end

    local ignore_extra = group:get("ignoreExtraMessages") or false

    if type(ignore_extra) ~= "boolean" then
      return configuration_error(
        "ignoreExtraMessages must be a boolean",
        group_path .. ".ignoreExtraMessages"
      )
    end

    local actual = retained_messages(
      runner,
      collector.messages,
      ignored,
      group_path .. ".ignoreMessages"
    )

    if #actual < #expected or not ignore_extra and #actual ~= #expected then
      return configuration_error(
        "observed log message count does not match"
          .. " (expected " .. #expected
          .. ", actual " .. #actual .. ")",
        group_path .. ".messages",
        { actual = #actual, expected = #expected }
      )
    end

    for message_index, wanted in expected:iter() do
      local matched
      matched, err = match_message(
        runner,
        wanted,
        actual[message_index],
        group_path .. ".messages[" .. message_index .. "]"
      )

      if not matched then
        return nil, err
      end
    end
  end

  return true
end

return M
