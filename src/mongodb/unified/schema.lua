local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local VALID_TYPES = {
  array = true,
  boolean = true,
  integer = true,
  null = true,
  number = true,
  object = true,
  string = true,
}

local VALIDATOR_STATES = setmetatable({}, { __mode = "k" })

local function schema_error(message, path, schema_path, keyword)
  return errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    message = message,
    details = {
      keyword = keyword,
      path = path,
      schema_path = schema_path,
    },
  })
end

local function append_path(path, key)
  if key:match("^[A-Za-z_][A-Za-z0-9_]*$") then
    return path .. "." .. key
  end

  return path .. "[" .. string.format("%q", key) .. "]"
end

local function append_schema_path(path, key)
  key = key:gsub("~", "~0"):gsub("/", "~1")
  return path .. "/" .. key
end

local function document_has(document, wanted)
  for key, value in document:iter() do
    if key == wanted then
      return true, value
    end
  end

  return false
end

local function number_value(value)
  if bson.is_exact(value) then
    return value:to_number()
  end

  if type(value) == "number" then
    return value
  end
end

local function value_type(value)
  if bson.is_document(value) then
    return "object"
  end

  if bson.is_array(value) then
    return "array"
  end

  if bson.is_null(value) then
    return "null"
  end

  if type(value) == "string" or type(value) == "boolean" then
    return type(value)
  end

  local number = number_value(value)

  if number ~= nil then
    if math.type(number) == "integer" or number % 1 == 0 then
      return "integer"
    end

    return "number"
  end

  return "bson"
end

local function matches_type(value, expected)
  local actual = value_type(value)

  if expected == "number" then
    return actual == "number" or actual == "integer"
  end

  return actual == expected
end

local function scalar_equal(left, right)
  local left_number = number_value(left)
  local right_number = number_value(right)

  if left_number ~= nil or right_number ~= nil then
    return left_number ~= nil and right_number ~= nil and left_number == right_number
  end

  if bson.is_null(left) or bson.is_null(right) then
    return bson.is_null(left) and bson.is_null(right)
  end

  return left == right
end

local function values_equal(left, right)
  if bson.is_document(left) or bson.is_document(right) then
    if not bson.is_document(left) or not bson.is_document(right) or #left ~= #right then
      return false
    end

    for index = 1, #left do
      local left_key, left_value = left:get_at(index)
      local right_key, right_value = right:get_at(index)

      if left_key ~= right_key or not values_equal(left_value, right_value) then
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

  return scalar_equal(left, right)
end

local function pattern_matches(pattern, value)
  if pattern == "^[0-9]+(\\.[0-9]+){1,2}$" then
    return value:match("^%d+%.%d+$") ~= nil
      or value:match("^%d+%.%d+%.%d+$") ~= nil
  end

  local provider = pattern:match("^%^([a-z]+)")

  if provider and pattern == "^" .. provider .. "(:[a-zA-Z0-9_]+)?$" then
    if value == provider then
      return true
    end

    local suffix = value:match("^" .. provider .. ":(.+)$")
    return suffix ~= nil and suffix:match("^[A-Za-z0-9_]+$") ~= nil
  end

  return nil, "unsupported JSON Schema pattern: " .. pattern
end

local function decode_pointer_token(token)
  return token:gsub("~1", "/"):gsub("~0", "~")
end

local function resolve_reference(root, reference)
  if reference == "#" then
    return root
  end

  if reference:sub(1, 2) ~= "#/" then
    return nil, "only local JSON Schema references are supported"
  end

  local current = root

  for token in reference:sub(3):gmatch("[^/]+") do
    if not bson.is_document(current) then
      return nil, "JSON Schema reference traverses a non-object"
    end

    current = current:get(decode_pointer_token(token))

    if current == nil then
      return nil, "unresolved JSON Schema reference: " .. reference
    end
  end

  return current
end

local validate_schema

local function validate_type(instance, type_schema, path, schema_path)
  local matched = false

  if type(type_schema) == "string" then
    if not VALID_TYPES[type_schema] then
      return nil, schema_error(
        "unsupported JSON Schema type: " .. type_schema,
        path,
        schema_path,
        "type"
      )
    end

    matched = matches_type(instance, type_schema)
  elseif bson.is_array(type_schema) then
    for _, expected in type_schema:iter() do
      if type(expected) ~= "string" or not VALID_TYPES[expected] then
        return nil, schema_error(
          "JSON Schema type array contains an unsupported type",
          path,
          schema_path,
          "type"
        )
      end

      matched = matched or matches_type(instance, expected)
    end
  else
    return nil, schema_error(
      "JSON Schema type must be a string or array",
      path,
      schema_path,
      "type"
    )
  end

  if not matched then
    return nil, schema_error(
      "value does not match the required JSON Schema type",
      path,
      schema_path,
      "type"
    )
  end

  return true
end

local function validate_enum(instance, choices, path, schema_path)
  if not bson.is_array(choices) then
    return nil, schema_error("JSON Schema enum must be an array", path, schema_path, "enum")
  end

  for _, choice in choices:iter() do
    if values_equal(instance, choice) then
      return true
    end
  end

  return nil, schema_error("value is not one of the allowed values", path, schema_path, "enum")
end

local function validate_required(instance, required, path, schema_path)
  if not bson.is_document(instance) then
    return true
  end

  if not bson.is_array(required) then
    return nil, schema_error("JSON Schema required must be an array", path, schema_path, "required")
  end

  for _, key in required:iter() do
    if type(key) ~= "string" then
      return nil, schema_error(
        "JSON Schema required entries must be strings",
        path,
        schema_path,
        "required"
      )
    end

    if not document_has(instance, key) then
      return nil, schema_error(
        "required property is missing: " .. key,
        append_path(path, key),
        schema_path,
        "required"
      )
    end
  end

  return true
end

local function validate_object(root, instance, schema, path, schema_path)
  if not bson.is_document(instance) then
    return true
  end

  local properties = schema:get("properties")
  local pattern_properties = schema:get("patternProperties")
  local additional = schema:get("additionalProperties")
  local minimum = number_value(schema:get("minProperties"))
  local maximum = number_value(schema:get("maxProperties"))

  if minimum and #instance < minimum then
    return nil, schema_error("object has too few properties", path, schema_path, "minProperties")
  end

  if maximum and #instance > maximum then
    return nil, schema_error("object has too many properties", path, schema_path, "maxProperties")
  end

  if properties ~= nil and not bson.is_document(properties) then
    return nil, schema_error(
      "JSON Schema properties must be an object",
      path,
      schema_path,
      "properties"
    )
  end

  if pattern_properties ~= nil and not bson.is_document(pattern_properties) then
    return nil, schema_error(
      "JSON Schema patternProperties must be an object",
      path,
      schema_path,
      "patternProperties"
    )
  end

  for key, value in instance:iter() do
    local property_path = append_path(path, key)
    local matched = false
    local property_schema = properties and properties:get(key)

    if property_schema ~= nil then
      matched = true
      local ok, err = validate_schema(
        root,
        value,
        property_schema,
        property_path,
        append_schema_path(append_schema_path(schema_path, "properties"), key)
      )

      if not ok then
        return nil, err
      end
    end

    if pattern_properties then
      for pattern, candidate_schema in pattern_properties:iter() do
        local pattern_matched, pattern_err = pattern_matches(pattern, key)

        if pattern_matched == nil then
          return nil, schema_error(pattern_err, property_path, schema_path, "patternProperties")
        end

        if pattern_matched then
          matched = true
          local ok, err = validate_schema(
            root,
            value,
            candidate_schema,
            property_path,
            append_schema_path(append_schema_path(schema_path, "patternProperties"), pattern)
          )

          if not ok then
            return nil, err
          end
        end
      end
    end

    if not matched and additional == false then
      return nil, schema_error(
        "additional property is not allowed: " .. key,
        property_path,
        append_schema_path(schema_path, "additionalProperties"),
        "additionalProperties"
      )
    elseif not matched and bson.is_document(additional) then
      local ok, err = validate_schema(
        root,
        value,
        additional,
        property_path,
        append_schema_path(schema_path, "additionalProperties")
      )

      if not ok then
        return nil, err
      end
    end
  end

  return true
end

local function validate_array(root, instance, schema, path, schema_path)
  if not bson.is_array(instance) then
    return true
  end

  local minimum = number_value(schema:get("minItems"))
  local maximum = number_value(schema:get("maxItems"))

  if minimum and #instance < minimum then
    return nil, schema_error("array has too few items", path, schema_path, "minItems")
  end

  if maximum and #instance > maximum then
    return nil, schema_error("array has too many items", path, schema_path, "maxItems")
  end

  local items = schema:get("items")

  if items ~= nil then
    for index, value in instance:iter() do
      local ok, err = validate_schema(
        root,
        value,
        items,
        path .. "[" .. index .. "]",
        append_schema_path(schema_path, "items")
      )

      if not ok then
        return nil, err
      end
    end
  end

  return true
end

local function validate_combinators(root, instance, schema, path, schema_path)
  local all_of = schema:get("allOf")

  if all_of then
    for index, candidate in all_of:iter() do
      local ok, err = validate_schema(
        root,
        instance,
        candidate,
        path,
        append_schema_path(append_schema_path(schema_path, "allOf"), tostring(index - 1))
      )

      if not ok then
        return nil, err
      end
    end
  end

  local one_of = schema:get("oneOf")

  if one_of then
    local matches = 0

    for index, candidate in one_of:iter() do
      local ok = validate_schema(
        root,
        instance,
        candidate,
        path,
        append_schema_path(append_schema_path(schema_path, "oneOf"), tostring(index - 1))
      )

      if ok then
        matches = matches + 1
      end
    end

    if matches ~= 1 then
      return nil, schema_error(
        "value must match exactly one oneOf schema",
        path,
        append_schema_path(schema_path, "oneOf"),
        "oneOf"
      )
    end
  end

  local negated = schema:get("not")

  if negated then
    local ok = validate_schema(
      root,
      instance,
      negated,
      path,
      append_schema_path(schema_path, "not")
    )

    if ok then
      return nil, schema_error(
        "value matches a prohibited schema",
        path,
        append_schema_path(schema_path, "not"),
        "not"
      )
    end
  end

  return true
end

validate_schema = function(root, instance, schema, path, schema_path)
  if type(schema) == "boolean" then
    if schema then
      return true
    end

    return nil, schema_error("value is rejected by the false schema", path, schema_path, "false")
  end

  if not bson.is_document(schema) then
    return nil, schema_error(
      "JSON Schema must be an object or boolean",
      path,
      schema_path,
      "schema"
    )
  end

  local reference = schema:get("$ref")

  if reference ~= nil then
    if type(reference) ~= "string" then
      return nil, schema_error("JSON Schema $ref must be a string", path, schema_path, "$ref")
    end

    local resolved, message = resolve_reference(root, reference)

    if not resolved then
      return nil, schema_error(message, path, schema_path, "$ref")
    end

    local ok, err = validate_schema(root, instance, resolved, path, reference)

    if not ok then
      return nil, err
    end
  end

  local type_schema = schema:get("type")

  if type_schema ~= nil then
    local ok, err = validate_type(
      instance,
      type_schema,
      path,
      append_schema_path(schema_path, "type")
    )

    if not ok then
      return nil, err
    end
  end

  local enum = schema:get("enum")

  if enum ~= nil then
    local ok, err = validate_enum(instance, enum, path, append_schema_path(schema_path, "enum"))

    if not ok then
      return nil, err
    end
  end

  local has_const, const = document_has(schema, "const")

  if has_const and not values_equal(instance, const) then
    return nil, schema_error(
      "value does not equal the required constant",
      path,
      append_schema_path(schema_path, "const"),
      "const"
    )
  end

  local pattern = schema:get("pattern")

  if pattern ~= nil and type(instance) == "string" then
    local matched, message = pattern_matches(pattern, instance)

    if matched == nil then
      return nil, schema_error(message, path, schema_path, "pattern")
    end

    if not matched then
      return nil, schema_error(
        "string does not match the required pattern",
        path,
        append_schema_path(schema_path, "pattern"),
        "pattern"
      )
    end
  end

  local required = schema:get("required")

  if required ~= nil then
    local ok, err = validate_required(
      instance,
      required,
      path,
      append_schema_path(schema_path, "required")
    )

    if not ok then
      return nil, err
    end
  end

  local ok, err = validate_combinators(root, instance, schema, path, schema_path)

  if not ok then
    return nil, err
  end

  ok, err = validate_object(root, instance, schema, path, schema_path)

  if not ok then
    return nil, err
  end

  return validate_array(root, instance, schema, path, schema_path)
end

local VALIDATOR_METHODS = {}
local VALIDATOR_METATABLE = {
  __index = VALIDATOR_METHODS,
  __metatable = "mongodb.unified.schema.validator",
  __newindex = function()
    error("unified schema validators are immutable", 2)
  end,
}

function VALIDATOR_METHODS:validate(document)
  local root = VALIDATOR_STATES[self].schema
  return validate_schema(root, document, root, "$", "#")
end

function M.compile(schema)
  if not bson.is_document(schema) then
    return nil, schema_error("JSON Schema root must be an object", "$", "#", "schema")
  end

  local validator = {}

  VALIDATOR_STATES[validator] = { schema = schema }
  return setmetatable(validator, VALIDATOR_METATABLE)
end

return M
