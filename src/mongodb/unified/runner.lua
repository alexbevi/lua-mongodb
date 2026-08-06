local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime")

local M = {}

local RUNNER_STATES = setmetatable({}, { __mode = "k" })

local function configuration_error(message, path, details)
  details = details or {}
  details.path = path or "$"

  return errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    message = message,
    details = details,
  })
end

local function append_path(path, key)
  if key:match("^[A-Za-z_][A-Za-z0-9_]*$") then
    return path .. "." .. key
  end

  return path .. "[" .. string.format("%q", key) .. "]"
end

local function document_has(document, wanted)
  if not bson.is_document(document) then
    return false
  end

  for key, value in document:iter() do
    if key == wanted then
      return true, value
    end
  end

  return false
end

local function as_number(value)
  if bson.is_exact(value, "int32")
    or bson.is_exact(value, "int64")
    or bson.is_exact(value, "double") then
    return value:to_number()
  end

  if type(value) == "number" then
    return value
  end
end

local function values_equal(left, right)
  local left_number = as_number(left)
  local right_number = as_number(right)

  if left_number ~= nil or right_number ~= nil then
    return left_number ~= nil and right_number ~= nil and left_number == right_number
  end

  if bson.is_null(left) or bson.is_null(right) then
    return bson.is_null(left) and bson.is_null(right)
  end

  if bson.is_document(left) or bson.is_document(right) then
    if not bson.is_document(left) or not bson.is_document(right) or #left ~= #right then
      return false
    end

    local right_entries = right:entries()
    local matched = {}

    for left_key, left_value in left:iter() do
      local found = false

      for index, entry in ipairs(right_entries) do
        if not matched[index]
          and left_key == entry[1]
          and values_equal(left_value, entry[2]) then
          matched[index] = true
          found = true
          break
        end
      end

      if not found then
        return false
      end
    end

    return true
  end

  if bson.is_array(left) or bson.is_array(right) then
    if not bson.is_array(left) or not bson.is_array(right) or #left ~= #right then
      return false
    end

    for index = 1, #left do
      if not values_equal(left:get(index), right:get(index)) then
        return false
      end
    end

    return true
  end

  if bson.is_tagged(left, "code") or bson.is_tagged(right, "code") then
    return bson.is_tagged(left, "code")
      and bson.is_tagged(right, "code")
      and left.source == right.source
      and values_equal(left.scope, right.scope)
  end

  return left == right
end

local function parse_version(value)
  if type(value) ~= "string" then
    return nil
  end

  local result = {}

  for component in value:gmatch("%d+") do
    result[#result + 1] = tonumber(component)
  end

  if #result < 2 or not value:match("^%d+%.%d+%.?%d*$") then
    return nil
  end

  return result
end

local function compare_versions(left, right)
  local left_parts = parse_version(left)
  local right_parts = parse_version(right)

  if not left_parts or not right_parts then
    return nil
  end

  for index = 1, math.max(#left_parts, #right_parts) do
    local difference = (left_parts[index] or 0) - (right_parts[index] or 0)

    if difference < 0 then
      return -1
    elseif difference > 0 then
      return 1
    end
  end

  return 0
end

local function array_contains(array, wanted)
  if not bson.is_array(array) then
    return false
  end

  for _, value in array:iter() do
    if value == wanted then
      return true
    end
  end

  return false
end

local function requirement_matches(environment, requirement)
  local minimum = requirement:get("minServerVersion")
  local maximum = requirement:get("maxServerVersion")

  if minimum and compare_versions(environment.server_version, minimum) ~= 1
    and compare_versions(environment.server_version, minimum) ~= 0 then
    return false
  end

  if maximum and compare_versions(environment.server_version, maximum) ~= -1
    and compare_versions(environment.server_version, maximum) ~= 0 then
    return false
  end

  local topologies = requirement:get("topologies")

  if topologies and not array_contains(topologies, environment.topology) then
    if environment.topology ~= "sharded-replicaset"
      or not array_contains(topologies, "sharded") then
      return false
    end
  end

  local has_auth, auth = document_has(requirement, "auth")

  if has_auth and auth ~= environment.auth then
    return false
  end

  local auth_mechanism = requirement:get("authMechanism")

  if auth_mechanism and auth_mechanism ~= environment.auth_mechanism then
    return false
  end

  local serverless = requirement:get("serverless")

  if serverless == "require" and not environment.serverless
    or serverless == "forbid" and environment.serverless then
    return false
  end

  local parameters = requirement:get("serverParameters")

  if parameters then
    if not bson.is_document(environment.server_parameters) then
      return false
    end

    for key, expected in parameters:iter() do
      local exists, actual = document_has(environment.server_parameters, key)

      if not exists or not values_equal(expected, actual) then
        return false
      end
    end
  end

  local csfle = requirement:get("csfle")

  if csfle == true and not environment.csfle then
    return false
  elseif bson.is_document(csfle) then
    local needed = csfle:get("minLibmongocryptVersion")
    local installed = environment.libmongocrypt_version

    if not installed or compare_versions(installed, needed) == -1 then
      return false
    end
  end

  return true
end

local function value_matches_alias(value, alias)
  if alias == "number" then
    return as_number(value) ~= nil or bson.is_exact(value, "decimal128")
  elseif alias == "int" then
    return bson.is_exact(value, "int32")
  elseif alias == "long" then
    return bson.is_exact(value, "int64")
  elseif alias == "double" then
    return bson.is_exact(value, "double")
  elseif alias == "decimal" then
    return bson.is_exact(value, "decimal128")
  elseif alias == "string" then
    return type(value) == "string"
  elseif alias == "object" then
    return bson.is_document(value)
  elseif alias == "array" then
    return bson.is_array(value)
  elseif alias == "binData" then
    return bson.is_binary(value)
  elseif alias == "bool" then
    return type(value) == "boolean"
  elseif alias == "null" then
    return bson.is_null(value)
  elseif alias == "objectId" then
    return bson.is_tagged(value, "object_id")
  elseif alias == "date" then
    return bson.is_tagged(value, "datetime")
  elseif alias == "regex" then
    return bson.is_tagged(value, "regex")
  elseif alias == "dbPointer" then
    return bson.is_tagged(value, "db_pointer")
  elseif alias == "undefined" then
    return bson.is_tagged(value, "undefined")
  elseif alias == "symbol" then
    return bson.is_tagged(value, "symbol")
  elseif alias == "timestamp" then
    return bson.is_tagged(value, "timestamp")
  elseif alias == "javascript" then
    return bson.is_tagged(value, "code") and value.scope == nil
  elseif alias == "javascriptWithScope" then
    return bson.is_tagged(value, "code") and value.scope ~= nil
  elseif alias == "minKey" then
    return bson.is_tagged(value, "min_key")
  elseif alias == "maxKey" then
    return bson.is_tagged(value, "max_key")
  end

  return nil
end

local match_value

local function match_error(message, path, operator)
  return nil, configuration_error(message, path, { operator = operator })
end

local function require_match(matched, message, path, operator)
  if matched then
    return true
  end

  return match_error(message, path, operator)
end

local function from_hex(value)
  if type(value) ~= "string" or #value % 2 ~= 0 or not value:match("^[0-9a-fA-F]*$") then
    return nil
  end

  return (value:gsub("..", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local function session_lsid(runner, name, path)
  local session, err = runner:get_entity(name, "session", path)

  if session == nil then
    return nil, err
  end

  local state = RUNNER_STATES[runner]
  local lsid

  if state.session_lsid then
    lsid = state.session_lsid(session)
  elseif bson.is_document(session) then
    lsid = session:get("lsid") or session:get("session_id")
  elseif type(session) == "table" then
    if type(session.get_lsid) == "function" then
      lsid = session:get_lsid()
    else
      lsid = session.lsid or session.session_id
    end
  end

  if not bson.is_document(lsid) then
    return nil, configuration_error(
      "session entity does not expose a logical session id",
      path,
      { entity = name }
    )
  end

  return lsid
end

local function match_operator(runner, operator, operand, actual, path, root)
  if operator == "$$exists" then
    return require_match(
      operand == true,
      "$$exists operand must be true for a present value",
      path,
      operator
    )
  elseif operator == "$$type" then
    local matched = false

    if type(operand) == "string" then
      matched = value_matches_alias(actual, operand)

      if matched == nil then
        return match_error("unknown BSON type alias: " .. operand, path, operator)
      end
    elseif bson.is_array(operand) then
      for _, alias in operand:iter() do
        local alias_match = value_matches_alias(actual, alias)

        if alias_match == nil then
          return match_error("unknown BSON type alias: " .. tostring(alias), path, operator)
        end

        matched = matched or alias_match
      end
    else
      return match_error("$$type operand must be a string or array", path, operator)
    end

    return require_match(matched, "value has the wrong BSON type", path, operator)
  elseif operator == "$$matchesEntity" then
    local expected, err = runner:get_entity(operand, "bson", path)

    if expected == nil then
      return nil, err
    end

    return match_value(runner, expected, actual, path, root)
  elseif operator == "$$matchesHexBytes" then
    local expected = from_hex(operand)

    if not expected then
      return match_error("$$matchesHexBytes operand is not hexadecimal", path, operator)
    end

    return require_match(
      type(actual) == "string" and actual == expected,
      "string value does not match the expected bytes",
      path,
      operator
    )
  elseif operator == "$$unsetOrMatches" then
    if actual == nil then
      return true
    end

    return match_value(runner, operand, actual, path, root)
  elseif operator == "$$sessionLsid" then
    local expected, err = session_lsid(runner, operand, path)

    if expected == nil then
      return nil, err
    end

    return require_match(
      values_equal(expected, actual),
      "value does not match the session logical id",
      path,
      operator
    )
  elseif operator == "$$lte" then
    local expected_number = as_number(operand)
    local actual_number = as_number(actual)

    return require_match(
      expected_number and actual_number and actual_number <= expected_number,
      "numeric value exceeds the expected bound",
      path,
      operator
    )
  elseif operator == "$$matchAsDocument" then
    if type(actual) ~= "string" then
      return match_error("$$matchAsDocument requires a JSON string", path, operator)
    end

    local parsed, err = bson.json.decode(actual)

    if not parsed then
      return nil, configuration_error(
        "could not parse match document",
        path,
        { cause = tostring(err) }
      )
    end

    return match_value(runner, operand, parsed, path, false)
  elseif operator == "$$matchAsRoot" then
    return match_value(runner, operand, actual, path, true)
  end

  return match_error("unsupported unified match operator: " .. operator, path, operator)
end

local function special_operator(value)
  if not bson.is_document(value) or #value ~= 1 then
    return nil
  end

  local key, operand = value:get_at(1)

  if key:sub(1, 2) == "$$" then
    return key, operand
  end
end

local function match_document(runner, expected, actual, path, root)
  if not bson.is_document(actual) then
    return match_error("expected an object", path)
  end

  local expected_present = 0

  for key, expected_value in expected:iter() do
    local child_path = append_path(path, key)
    local exists, actual_value = document_has(actual, key)
    local operator, operand = special_operator(expected_value)

    if operator == "$$exists" then
      if type(operand) ~= "boolean" then
        return match_error("$$exists operand must be boolean", child_path, operator)
      end

      if exists ~= operand then
        return match_error("property existence does not match", child_path, operator)
      end

      if operand then
        expected_present = expected_present + 1
      end
    elseif not (operator == "$$unsetOrMatches" and not exists) then
      if not exists then
        return match_error("expected property is missing", child_path)
      end

      expected_present = expected_present + 1
      local ok, err = match_value(runner, expected_value, actual_value, child_path, false)

      if not ok then
        return nil, err
      end
    end
  end

  if not root and #actual ~= expected_present then
    return match_error("nested object contains unexpected properties", path)
  end

  return true
end

match_value = function(runner, expected, actual, path, root)
  local operator, operand = special_operator(expected)

  if operator then
    return match_operator(runner, operator, operand, actual, path, root)
  end

  if bson.is_document(expected) then
    return match_document(runner, expected, actual, path, root)
  end

  if bson.is_array(expected) then
    if not bson.is_array(actual) or #expected ~= #actual then
      return match_error("array length does not match", path)
    end

    for index, expected_value in expected:iter() do
      local item_root = root and bson.is_document(expected_value)
      local ok, err = match_value(
        runner,
        expected_value,
        actual:get(index),
        path .. "[" .. index .. "]",
        item_root
      )

      if not ok then
        return nil, err
      end
    end

    return true
  end

  return require_match(values_equal(expected, actual), "values do not match", path)
end

local RUNNER_METHODS = {}
local RUNNER_METATABLE = {
  __index = RUNNER_METHODS,
  __metatable = "mongodb.unified.runner",
  __newindex = function()
    error("unified runners are immutable", 2)
  end,
}

function RUNNER_METHODS:add_entity(id, kind, value)
  local state = RUNNER_STATES[self]

  if type(id) ~= "string" or id == "" then
    return nil, configuration_error("entity id must be a non-empty string", "$.id")
  end

  if type(kind) ~= "string" or kind == "" then
    return nil, configuration_error("entity kind must be a non-empty string", "$.kind")
  end

  if value == nil then
    return nil, configuration_error("entity value cannot be nil", "$.value")
  end

  if state.entities[id] then
    return nil, configuration_error("duplicate entity id: " .. id, "$.id")
  end

  state.entities[id] = { kind = kind, value = value }
  return true
end

function RUNNER_METHODS:get_entity(id, expected_kind, path)
  local entity = RUNNER_STATES[self].entities[id]

  if not entity then
    return nil, configuration_error("unknown entity: " .. tostring(id), path or "$.object")
  end

  if expected_kind and entity.kind ~= expected_kind then
    return nil, configuration_error(
      "entity " .. id .. " has kind " .. entity.kind .. ", expected " .. expected_kind,
      path or "$.object"
    )
  end

  return entity.value, entity.kind
end

function RUNNER_METHODS:should_run(requirements)
  if requirements == nil or bson.is_array(requirements) and #requirements == 0 then
    return true
  end

  if not bson.is_array(requirements) then
    return false
  end

  local environment = RUNNER_STATES[self].environment

  for _, requirement in requirements:iter() do
    if bson.is_document(requirement) and requirement_matches(environment, requirement) then
      return true
    end
  end

  return false
end

function RUNNER_METHODS:create_entities(specifications, path)
  path = path or "$.createEntities"

  if not bson.is_array(specifications) then
    return nil, configuration_error("createEntities must be an array", path)
  end

  local state = RUNNER_STATES[self]

  for index, outer in specifications:iter() do
    local entity_path = path .. "[" .. index .. "]"

    if not bson.is_document(outer) or #outer ~= 1 then
      return nil, configuration_error(
        "entity definition must contain exactly one kind",
        entity_path
      )
    end

    local kind, specification = outer:get_at(1)

    if not bson.is_document(specification) then
      return nil, configuration_error("entity specification must be an object", entity_path)
    end

    local id = specification:get("id")
    local value

    if kind == "thread" then
      value = { tasks = {} }
    else
      local factory = state.entity_factories[kind]

      if not factory then
        return nil, configuration_error(
          "unsupported unified entity kind: " .. kind,
          append_path(entity_path, kind),
          { entity_kind = kind }
        )
      end

      local err
      value, err = factory(self, specification)

      if value == nil then
        return nil, err or configuration_error("entity factory returned no value", entity_path)
      end
    end

    local ok, err = self:add_entity(id, kind, value)

    if not ok then
      return nil, err
    end
  end

  return true
end

function RUNNER_METHODS:match(expected, actual, path)
  return match_value(self, expected, actual, path or "$", true)
end

local function execute_regular(runner, operation, path)
  local state = RUNNER_STATES[runner]
  local name = operation:get("name")
  local object = operation:get("object")
  local entity, kind = runner:get_entity(object, nil, append_path(path, "object"))

  if entity == nil then
    return nil, kind
  end

  local handlers = state.operations[kind]
  local handler = handlers and handlers[name]

  if not handler then
    return nil, configuration_error(
      "unsupported unified operation " .. tostring(name) .. " for " .. kind,
      append_path(path, "name"),
      { entity_kind = kind, operation = name }
    )
  end

  local arguments = operation:get("arguments") or bson.document({})
  local result, err = handler(runner, entity, arguments, operation)
  local has_expect_error, expect_error = document_has(operation, "expectError")

  if err then
    if not has_expect_error then
      return nil, err
    end

    local contains = expect_error:get("errorContains")

    if contains and not err.message:find(contains, 1, true) then
      return nil, configuration_error("error message did not contain expectation", path)
    end

    return true
  elseif has_expect_error then
    return nil, configuration_error("operation succeeded but an error was expected", path)
  end

  local has_expected, expected = document_has(operation, "expectResult")

  if has_expected then
    local ok, match_err = runner:match(expected, result, append_path(path, "expectResult"))

    if not ok then
      return nil, match_err
    end
  end

  local save_as = operation:get("saveResultAsEntity")

  if save_as then
    local ok, save_err = runner:add_entity(save_as, "bson", result)

    if not ok then
      return nil, save_err
    end
  end

  return true, result
end

local function run_thread(runner, arguments, path)
  local state = RUNNER_STATES[runner]
  local name = arguments:get("thread")
  local thread, err = runner:get_entity(name, "thread", append_path(path, "thread"))

  if not thread then
    return nil, err
  end

  local operation = arguments:get("operation")
  local task = state.runtime.task:spawn(function()
    local ok, operation_err = runner:execute(operation, append_path(path, "operation"))

    if not ok then
      error(operation_err, 0)
    end

    return ok
  end)

  thread.tasks[#thread.tasks + 1] = task
  return true
end

local function wait_for_thread(runner, arguments, path)
  local state = RUNNER_STATES[runner]
  local name = arguments:get("thread")
  local thread, err = runner:get_entity(name, "thread", append_path(path, "thread"))

  if not thread then
    return nil, err
  end

  for _, task in ipairs(thread.tasks) do
    local ok, task_err = state.runtime.task:await(task)

    if not ok then
      if errors.is(task_err) then
        return nil, task_err
      end

      return nil, configuration_error("thread operation failed: " .. tostring(task_err), path)
    end
  end

  thread.tasks = {}
  return true
end

local function store_counter(runner, name, value)
  if not name then
    return true
  end

  local state = RUNNER_STATES[runner]
  local entity = state.entities[name]

  if entity then
    entity.value = bson.int64(value)
    return true
  end

  return runner:add_entity(name, "bson", bson.int64(value))
end

local function run_loop(runner, arguments, path)
  local iterations = as_number(arguments:get("numIterations"))

  if math.type(iterations) ~= "integer" or iterations < 0 then
    return nil, configuration_error(
      "deterministic loop requires non-negative numIterations",
      append_path(path, "numIterations")
    )
  end

  local operations = arguments:get("operations")

  if not bson.is_array(operations) then
    return nil, configuration_error(
      "loop operations must be an array",
      append_path(path, "operations")
    )
  end

  local successes = 0

  for iteration = 1, iterations do
    local ok, err = store_counter(runner, arguments:get("storeIterationsAsEntity"), iteration)

    if not ok then
      return nil, err
    end

    for index, operation in operations:iter() do
      ok, err = runner:execute(
        operation,
        append_path(path, "operations") .. "[" .. index .. "]"
      )

      if not ok then
        return nil, err
      end

      successes = successes + 1
      ok, err = store_counter(runner, arguments:get("storeSuccessesAsEntity"), successes)

      if not ok then
        return nil, err
      end
    end
  end

  return true
end

local SPECIAL_OPERATIONS = {
  loop = run_loop,
  runOnThread = run_thread,
  waitForThread = wait_for_thread,
}

function RUNNER_METHODS:execute(operation, path)
  path = path or "$.operation"

  if not bson.is_document(operation) then
    return nil, configuration_error("operation must be an object", path)
  end

  if operation:get("object") ~= "testRunner" then
    return execute_regular(self, operation, path)
  end

  local state = RUNNER_STATES[self]
  local name = operation:get("name")
  local handler = SPECIAL_OPERATIONS[name] or state.test_operations[name]

  if not handler then
    return nil, configuration_error(
      "unsupported special test operation: " .. tostring(name),
      append_path(path, "name"),
      { operation = name }
    )
  end

  return handler(self, operation:get("arguments") or bson.document({}), path)
end

function RUNNER_METHODS:execute_all(operations, path)
  path = path or "$.operations"

  if not bson.is_array(operations) then
    return nil, configuration_error("operations must be an array", path)
  end

  for index, operation in operations:iter() do
    local ok, err = self:execute(operation, path .. "[" .. index .. "]")

    if not ok then
      return nil, err
    end
  end

  return true
end

function RUNNER_METHODS:verify_outcomes(outcomes, path)
  path = path or "$.outcome"
  local reader = RUNNER_STATES[self].outcome_reader

  if type(reader) ~= "function" then
    return nil, configuration_error("no outcome reader is configured", path)
  end

  for index, specification in outcomes:iter() do
    local actual, err = reader(self, specification)

    if actual == nil then
      return nil, err or configuration_error("outcome reader returned no value", path)
    end

    local expected = specification:get("documents")
    local ok, match_err = match_value(
      self,
      expected,
      actual,
      path .. "[" .. index .. "].documents",
      false
    )

    if not ok then
      return nil, match_err
    end
  end

  return true
end

local function copy_handlers(source)
  local result = {}

  for kind, handlers in pairs(source or {}) do
    result[kind] = {}

    for name, handler in pairs(handlers) do
      if type(handler) ~= "function" then
        error("unified operation handlers must be functions", 3)
      end

      result[kind][name] = handler
    end
  end

  return result
end

function M.new(options)
  options = options or {}

  if type(options) ~= "table" then
    error("unified runner options must be a table", 2)
  end

  if options.session_lsid ~= nil and type(options.session_lsid) ~= "function" then
    error("unified runner session_lsid must be a function", 2)
  end

  local runtime = runtime_contract.validate(options.runtime)
  local runner = {}
  local environment = options.environment or {}

  RUNNER_STATES[runner] = {
    entities = {},
    entity_factories = options.entity_factories or {},
    environment = {
      auth = environment.auth == true,
      auth_mechanism = environment.auth_mechanism,
      csfle = environment.csfle == true,
      libmongocrypt_version = environment.libmongocrypt_version,
      server_parameters = environment.server_parameters or bson.document({}),
      server_version = environment.server_version or "0.0",
      serverless = environment.serverless == true,
      topology = environment.topology or "single",
    },
    operations = copy_handlers(options.operations),
    outcome_reader = options.outcome_reader,
    runtime = runtime,
    session_lsid = options.session_lsid,
    test_operations = options.test_operations or {},
  }

  return setmetatable(runner, RUNNER_METATABLE)
end

return M
