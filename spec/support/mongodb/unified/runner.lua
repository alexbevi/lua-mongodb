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
  state.entity_order[#state.entity_order + 1] = id
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

function RUNNER_METHODS:each_entity(callback)
  if type(callback) ~= "function" then
    error("unified entity visitor must be a function", 2)
  end

  local state = RUNNER_STATES[self]

  for _, id in ipairs(state.entity_order) do
    local entity = state.entities[id]

    if entity then
      callback(id, entity.kind, entity.value)
    end
  end

  return true
end

function RUNNER_METHODS:add_finalizer(callback)
  if type(callback) ~= "function" then
    error("unified finalizer must be a function", 2)
  end

  local finalizers = RUNNER_STATES[self].finalizers

  finalizers[#finalizers + 1] = callback
  return true
end

local function cleanup_error(value)
  if errors.is(value) then
    return value
  end

  return configuration_error("unified cleanup failed: " .. tostring(value), "$.cleanup")
end

local function call_cleanup(callback, ...)
  local result = table.pack(pcall(callback, ...))

  if not result[1] then
    return nil, cleanup_error(result[2])
  end

  if result[2] == false or result[2] == nil and result[3] ~= nil then
    return nil, cleanup_error(result[3])
  end

  return true
end

function RUNNER_METHODS:run_finalizers()
  local finalizers = RUNNER_STATES[self].finalizers
  local first_error

  while #finalizers > 0 do
    local callback = table.remove(finalizers)
    local ok, err = call_cleanup(callback, self)

    if not ok and first_error == nil then
      first_error = err
    end
  end

  if first_error then
    return nil, first_error
  end

  return true
end


local function cleanup_thread(state, thread)
  for _, task in ipairs(thread.tasks) do
    local ok, err = state.runtime.task:await(task)

    if not ok then
      return nil, err
    end
  end

  thread.tasks = {}
  return true
end

local function cleanup_entity(runner, state, id, entity)
  local callback = state.entity_finalizers[entity.kind]

  if callback then
    return call_cleanup(callback, runner, entity.value, id)
  end

  if entity.kind == "thread" then
    return call_cleanup(cleanup_thread, state, entity.value)
  end

  local method_name = entity.kind == "session" and "end_session" or "close"
  local method = type(entity.value) == "table" and entity.value[method_name]

  if type(method) == "function" then
    return call_cleanup(method, entity.value)
  end

  return true
end

function RUNNER_METHODS:cleanup()
  local state = RUNNER_STATES[self]
  local _, first_error = self:run_finalizers()

  for index = #state.entity_order, 1, -1 do
    local id = state.entity_order[index]
    local entity = state.entities[id]

    if entity then
      local ok, err = cleanup_entity(self, state, id, entity)

      if not ok and first_error == nil then
        first_error = err
      end
    end
  end

  state.entities = {}
  state.entity_order = {}

  if first_error then
    return nil, first_error
  end

  return true
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

local function camel_case(name)
  return (name:gsub("_([a-z])", function(character)
    return character:upper()
  end))
end

local function is_bson_value(value)
  local value_type = type(value)

  return value_type == "boolean"
    or value_type == "number"
    or value_type == "string"
    or bson.is_array(value)
    or bson.is_binary(value)
    or bson.is_document(value)
    or bson.is_exact(value)
    or bson.is_null(value)
    or bson.is_tagged(value)
end

local function table_to_bson(value)
  if is_bson_value(value) then
    return value
  end

  if type(value) ~= "table" then
    return value
  end

  local length = #value
  local count = 0
  local sequence = length > 0

  for key in pairs(value) do
    count = count + 1

    if math.type(key) ~= "integer" or key < 1 or key > length then
      sequence = false
    end
  end

  if sequence and count == length then
    local items = {}

    for index = 1, length do
      items[index] = table_to_bson(value[index])
    end

    return bson.array(items)
  end

  local entries = {}

  for key, item in pairs(value) do
    if item ~= nil then
      entries[#entries + 1] = {
        camel_case(tostring(key)),
        table_to_bson(item),
      }
    end
  end

  table.sort(entries, function(left, right)
    return left[1] < right[1]
  end)
  return bson.document(entries)
end

local function write_errors_document(value)
  if bson.is_document(value) then
    return value
  end

  if type(value) ~= "table" then
    return nil
  end

  local entries = {}

  for _, item in ipairs(value) do
    local index = item.index

    if math.type(index) ~= "integer" or index < 1 then
      return nil
    end

    local fields = {}

    for key, field in pairs(item) do
      if key ~= "index" and field ~= nil then
        fields[#fields + 1] = { camel_case(tostring(key)), table_to_bson(field) }
      end
    end

    table.sort(fields, function(left, right)
      return left[1] < right[1]
    end)
    entries[#entries + 1] = { tostring(index - 1), bson.document(fields) }
  end

  return bson.document(entries)
end

local function write_concern_errors_array(value)
  if bson.is_array(value) then
    return value
  end

  if type(value) ~= "table" then
    return nil
  end

  local items = {}

  for index, item in ipairs(value) do
    items[index] = table_to_bson(item)
  end

  return bson.array(items)
end

local function expectation_mismatch(message, path, field)
  return nil, configuration_error(message, append_path(path, field))
end

local function error_response(err)
  local details = err.details
  return details and details.response or nil
end

local function error_is_client(err)
  return err.category ~= errors.CATEGORY.SERVER
    and error_response(err) == nil
end

local function assert_expected_error(runner, err, expected, path, coerce_result)
  if not errors.is(err) then
    return expectation_mismatch("operation returned an unstructured error", path, "expectError")
  end

  local supported_fields = {
    errorCode = true,
    errorCodeName = true,
    errorContains = true,
    errorLabelsContain = true,
    errorLabelsOmit = true,
    errorResponse = true,
    expectResult = true,
    isClientError = true,
    isError = true,
    isTimeoutError = true,
    writeConcernErrors = true,
    writeErrors = true,
  }

  for key, value in expected:iter() do
    if not supported_fields[key] then
      return expectation_mismatch("unsupported expected error field", path, key)
    end

    if key == "isError" and value ~= true then
      return expectation_mismatch("isError must be true", path, key)
    end
  end

  local present, wanted = document_has(expected, "isClientError")

  if present and error_is_client(err) ~= wanted then
    return expectation_mismatch("error client origin does not match", path, "isClientError")
  end

  present, wanted = document_has(expected, "isTimeoutError")

  if present and err:is_timeout() ~= wanted then
    return expectation_mismatch("error timeout status does not match", path, "isTimeoutError")
  end

  local contains = expected:get("errorContains")

  if contains and not tostring(err):lower():find(contains:lower(), 1, true) then
    return expectation_mismatch("error message did not contain expectation", path, "errorContains")
  end

  local code = expected:get("errorCode")

  if code and err.code ~= as_number(code) then
    return expectation_mismatch("error code does not match", path, "errorCode")
  end

  local code_name = expected:get("errorCodeName")

  if code_name and (type(err.code_name) ~= "string"
    or err.code_name:lower() ~= code_name:lower()) then
    return expectation_mismatch("error code name does not match", path, "errorCodeName")
  end

  local labels = expected:get("errorLabelsContain")

  if labels then
    for _, label in labels:iter() do
      if not err:has_label(label) then
        return expectation_mismatch("error is missing label " .. label, path, "errorLabelsContain")
      end
    end
  end

  labels = expected:get("errorLabelsOmit")

  if labels then
    for _, label in labels:iter() do
      if err:has_label(label) then
        return expectation_mismatch(
          "error unexpectedly has label " .. label,
          path,
          "errorLabelsOmit"
        )
      end
    end
  end

  local expected_write_errors = expected:get("writeErrors")

  if expected_write_errors then
    local actual = write_errors_document(err.details and err.details.write_errors)

    if not actual then
      return expectation_mismatch("error has no write errors", path, "writeErrors")
    end

    if #actual ~= #expected_write_errors then
      return expectation_mismatch("write error count does not match", path, "writeErrors")
    end

    for index, expected_write_error in expected_write_errors:iter() do
      local exists, actual_write_error = document_has(actual, index)

      if not exists then
        return expectation_mismatch("write error index is missing", path, "writeErrors")
      end

      local ok, match_err = runner:match(
        expected_write_error,
        actual_write_error,
        append_path(append_path(path, "writeErrors"), index)
      )

      if not ok then
        return nil, match_err
      end
    end
  end

  local expected_concern_errors = expected:get("writeConcernErrors")

  if expected_concern_errors then
    local actual = write_concern_errors_array(
      err.details and err.details.write_concern_errors
    )

    if not actual then
      return expectation_mismatch(
        "error has no write concern errors",
        path,
        "writeConcernErrors"
      )
    end

    local ok, match_err = runner:match(
      expected_concern_errors,
      actual,
      append_path(path, "writeConcernErrors")
    )

    if not ok then
      return nil, match_err
    end
  end

  local expected_response = expected:get("errorResponse")

  if expected_response then
    local response = error_response(err)

    if not bson.is_document(response) then
      return expectation_mismatch("error has no server response", path, "errorResponse")
    end

    local ok, match_err = runner:match(
      expected_response,
      response,
      append_path(path, "errorResponse")
    )

    if not ok then
      return nil, match_err
    end
  end

  local expected_result = expected:get("expectResult")

  if expected_result then
    local result = err.details and err.details.partial_result

    if result ~= nil and coerce_result then
      result = coerce_result(result)
    end

    local ok, match_err = runner:match(
      expected_result,
      coerce_result and result or table_to_bson(result),
      append_path(path, "expectResult")
    )

    if not ok then
      return nil, match_err
    end
  end

  return true
end

local function prepare_arguments(runner, descriptor, arguments, path)
  if not bson.is_document(arguments) then
    return nil, configuration_error("operation arguments must be an object", path)
  end

  local entries = {}

  for key, value in arguments:iter() do
    local argument_path = append_path(path, key)

    if descriptor.arguments and not descriptor.arguments[key] and key ~= "session"
        and key ~= "timeoutMS" and key ~= "timeoutMode"
    then
      return nil, configuration_error(
        "unsupported argument " .. key,
        argument_path,
        { argument = key }
      )
    end

    if key == "session" then
      local session, err = runner:get_entity(value, "session", argument_path)

      if session == nil then
        return nil, err
      end

      value = session
    end

    entries[#entries + 1] = { key, value }
  end

  return bson.document(entries)
end

local function operation_contract(operation, path)
  local has_error = document_has(operation, "expectError")
  local has_result = document_has(operation, "expectResult")
  local has_save = document_has(operation, "saveResultAsEntity")
  local ignore = operation:get("ignoreResultAndError") == true

  if ignore and (has_error or has_result or has_save) then
    return nil, configuration_error(
      "ignoreResultAndError conflicts with result, error, or saved entity assertions",
      path
    )
  end

  if has_error and (has_result or has_save) then
    return nil, configuration_error(
      "expectError conflicts with result or saved entity assertions",
      path
    )
  end

  return true
end

local function execute_regular(runner, operation, path, propagate_callback_errors)
  local state = RUNNER_STATES[runner]
  local name = operation:get("name")
  local object = operation:get("object")
  local entity, kind = runner:get_entity(object, nil, append_path(path, "object"))

  if entity == nil then
    return nil, kind
  end

  local handlers = state.operations[kind]
  local descriptor = handlers and handlers[name]

  if not descriptor then
    return nil, configuration_error(
      "unsupported unified operation " .. tostring(name) .. " for " .. kind,
      append_path(path, "name"),
      { entity_kind = kind, operation = name }
    )
  end

  local valid, validation_err = operation_contract(operation, path)

  if not valid then
    return nil, validation_err
  end

  local arguments, argument_err = prepare_arguments(
    runner,
    descriptor,
    operation:get("arguments") or bson.document({}),
    append_path(path, "arguments")
  )

  if not arguments then
    return nil, argument_err
  end

  local result, err = descriptor.handler(runner, entity, arguments, operation, path)
  local has_expect_error, expect_error = document_has(operation, "expectError")
  local ignore = operation:get("ignoreResultAndError") == true

  if err and not errors.is(err) then
    return nil, configuration_error("operation returned an unstructured error", path)
  end

  if ignore then
    if err and errors.is(err, errors.CATEGORY.CONFIGURATION) then
      return nil, err
    end

    if err and propagate_callback_errors then
      return nil, err
    end

    return true
  end

  if err then
    if not has_expect_error then
      return nil, err
    end

    local matched, match_err = assert_expected_error(
      runner,
      err,
      expect_error,
      append_path(path, "expectError"),
      descriptor.coerce_result
    )

    if not matched then
      return nil, match_err
    end

    if propagate_callback_errors then
      return nil, err
    end

    return true
  elseif has_expect_error then
    return nil, configuration_error("operation succeeded but an error was expected", path)
  end

  local has_expected, expected = document_has(operation, "expectResult")

  if has_expected then
    local comparable = result

    if descriptor.coerce_result then
      comparable = descriptor.coerce_result(result)
    end

    local ok, match_err = runner:match(
      expected,
      comparable,
      append_path(path, "expectResult")
    )

    if not ok then
      return nil, match_err
    end
  end

  local save_as = operation:get("saveResultAsEntity")

  if save_as then
    local result_kind = descriptor.result_kind

    if result == nil then
      return nil, configuration_error(
        "operation returned no result to save",
        append_path(path, "saveResultAsEntity")
      )
    end

    if result_kind == nil and is_bson_value(result) then
      result_kind = "bson"
    end

    if result_kind == nil or result_kind == "bson" and not is_bson_value(result) then
      return nil, configuration_error(
        "operation result has an unsupported entity type",
        append_path(path, "saveResultAsEntity")
      )
    end

    local ok, save_err = runner:add_entity(save_as, result_kind, result)

    if not ok then
      return nil, save_err
    end
  end

  return true, result
end

local function validate_special_arguments(arguments, allowed, path)
  for key in arguments:iter() do
    if not allowed[key] then
      return nil, configuration_error(
        "unsupported special operation argument " .. key,
        append_path(append_path(path, "arguments"), key),
        { argument = key }
      )
    end
  end

  return true
end

local function run_thread(runner, arguments, path)
  local valid, validation_err = validate_special_arguments(arguments, {
    operation = true,
    thread = true,
  }, path)

  if not valid then
    return nil, validation_err
  end

  local state = RUNNER_STATES[runner]
  local name = arguments:get("thread")
  local thread, err = runner:get_entity(name, "thread", append_path(path, "thread"))

  if not thread then
    return nil, err
  end

  local operation = arguments:get("operation")
  local started = false
  local task = state.runtime.task:spawn(function()
    started = true
    local ok, operation_err = runner:execute(operation, append_path(path, "operation"))

    if not ok then
      error(operation_err, 0)
    end

    return ok
  end)

  thread.tasks[#thread.tasks + 1] = task
  state.runtime.task:yield_control()

  if not started then
    error("runtime did not start the dispatched thread operation", 0)
  end

  return true
end

local function wait_for_thread(runner, arguments, path)
  local valid, validation_err = validate_special_arguments(arguments, {
    thread = true,
  }, path)

  if not valid then
    return nil, validation_err
  end

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

local function wait_operation(runner, arguments, path)
  local valid, validation_err = validate_special_arguments(arguments, {
    ms = true,
  }, path)

  if not valid then
    return nil, validation_err
  end

  local milliseconds = arguments:get("ms")

  if bson.is_exact(milliseconds) then
    milliseconds = milliseconds:to_number()
  end

  if math.type(milliseconds) ~= "integer" or milliseconds < 0 then
    return nil, configuration_error(
      "wait ms must be a non-negative integer",
      append_path(path, "ms")
    )
  end

  return RUNNER_STATES[runner].runtime.clock:sleep(milliseconds / 1000)
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
  local valid, validation_err = validate_special_arguments(arguments, {
    numIterations = true,
    operations = true,
    storeIterationsAsEntity = true,
    storeSuccessesAsEntity = true,
  }, path)

  if not valid then
    return nil, validation_err
  end

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

local function create_entities_operation(runner, arguments, path)
  local valid, validation_err = validate_special_arguments(arguments, {
    entities = true,
  }, path)

  if not valid then
    return nil, validation_err
  end

  return runner:create_entities(
    arguments:get("entities"),
    append_path(append_path(path, "arguments"), "entities")
  )
end

local SPECIAL_OPERATIONS = {
  createEntities = create_entities_operation,
  loop = run_loop,
  runOnThread = run_thread,
  wait = wait_operation,
  waitForThread = wait_for_thread,
}

function RUNNER_METHODS:execute(operation, path, propagate_callback_errors)
  path = path or "$.operation"

  if not bson.is_document(operation) then
    return nil, configuration_error("operation must be an object", path)
  end

  if operation:get("object") ~= "testRunner" then
    return execute_regular(self, operation, path, propagate_callback_errors)
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

function RUNNER_METHODS:execute_all(operations, path, propagate_callback_errors)
  path = path or "$.operations"

  if not bson.is_array(operations) then
    return nil, configuration_error("operations must be an array", path)
  end

  for index, operation in operations:iter() do
    local ok, err = self:execute(
      operation,
      path .. "[" .. index .. "]",
      propagate_callback_errors
    )

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

local SAVED_RESULT_KINDS = {
  bson = true,
  changeStream = true,
  collection = true,
  commandCursor = true,
  findCursor = true,
}

local function copy_handlers(source)
  local result = {}

  for kind, handlers in pairs(source or {}) do
    result[kind] = {}

    for name, definition in pairs(handlers) do
      local descriptor

      if type(definition) == "function" then
        descriptor = { handler = definition }
      elseif type(definition) == "table" then
        for key in pairs(definition) do
          if key ~= "arguments" and key ~= "coerce_result"
            and key ~= "handler" and key ~= "result_kind" then
            error("unknown unified operation descriptor option: " .. tostring(key), 3)
          end
        end

        if type(definition.handler) ~= "function" then
          error("unified operation descriptor handler must be a function", 3)
        end

        if definition.coerce_result ~= nil
          and type(definition.coerce_result) ~= "function" then
          error("unified operation coerce_result must be a function", 3)
        end

        if definition.result_kind ~= nil
          and (type(definition.result_kind) ~= "string"
            or not SAVED_RESULT_KINDS[definition.result_kind]) then
          error("unified operation result_kind is unsupported", 3)
        end

        local arguments

        if definition.arguments ~= nil then
          if type(definition.arguments) ~= "table" then
            error("unified operation arguments must be an array", 3)
          end

          arguments = {}

          for index, argument in ipairs(definition.arguments) do
            if type(argument) ~= "string" or argument == "" then
              error("unified operation arguments must contain strings", 3)
            end

            arguments[argument] = true

            if definition.arguments[index] ~= argument then
              error("unified operation arguments must be a dense array", 3)
            end
          end

          for key in pairs(definition.arguments) do
            if math.type(key) ~= "integer"
              or key < 1 or key > #definition.arguments then
              error("unified operation arguments must be a dense array", 3)
            end
          end
        end

        descriptor = {
          arguments = arguments,
          coerce_result = definition.coerce_result,
          handler = definition.handler,
          result_kind = definition.result_kind,
        }
      else
        error("unified operation handlers must be functions or descriptors", 3)
      end

      result[kind][name] = descriptor
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

  for kind, callback in pairs(options.entity_finalizers or {}) do
    if type(kind) ~= "string" or type(callback) ~= "function" then
      error("unified entity finalizers must map kinds to functions", 2)
    end
  end

  local runtime = runtime_contract.validate(options.runtime)
  local runner = {}
  local environment = options.environment or {}

  RUNNER_STATES[runner] = {
    entities = {},
    entity_finalizers = options.entity_finalizers or {},
    entity_factories = options.entity_factories or {},
    entity_order = {},
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
    finalizers = {},
  }

  return setmetatable(runner, RUNNER_METATABLE)
end

return M
