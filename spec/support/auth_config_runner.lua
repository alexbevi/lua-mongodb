local bson = require("mongodb.bson")
local credentials = require("mongodb.config.credentials")
local luassert = require("luassert")
local options = require("mongodb.config.options")
local uri = require("mongodb.config.uri")

local M = {}

local ROOT = os.getenv("PWD") or "."
local FIXTURE = ROOT
  .. "/planning/specifications/source/auth/tests/legacy/connection-string.json"
local AUTH_002_CASES = {
  [1] = true,
  [2] = true,
  [3] = true,
  [12] = true,
  [13] = true,
  [27] = true,
  [28] = true,
  [29] = true,
  [30] = true,
  [31] = true,
  [32] = true,
  [33] = true,
  [34] = true,
  [35] = true,
  [36] = true,
  [37] = true,
  [38] = true,
  [39] = true,
}
local AUTH_003_CASES = {
  [23] = true,
  [24] = true,
  [25] = true,
  [26] = true,
}

local function load_fixture()
  local file = assert(io.open(FIXTURE, "rb"))
  local document = assert(bson.json.decode(file:read("*a")))

  file:close()
  return document
end

local function normalize(value)
  local parsed, err = uri.parse(value)

  if not parsed then
    return nil, err
  end

  local config
  config, err = options.normalize(parsed.options, nil, parsed)

  if not config then
    return nil, err
  end

  return credentials.build(parsed, config)
end

local function expected_value(document, name)
  local value = document:get(name)

  if bson.is_null(value) then
    return nil
  end

  return value
end

local function run_cases(cases)
  local count = 0

  for index, test in load_fixture():get("tests"):iter() do
    if cases[index] then
      local description = test:get("description")
      local credential, err = normalize(test:get("uri"))

      assert((credential ~= nil or err == nil) == test:get("valid"), description)

      if test:get("valid") then
        luassert.is_nil(err, description)
        local expected = test:get("credential")

        if bson.is_null(expected) then
          luassert.is_nil(credential, description)
        else
          for _, name in ipairs({ "mechanism", "password", "source", "username" }) do
            luassert.are.equal(
              expected_value(expected, name),
              credential[name],
              description .. ": " .. name
            )
          end

          luassert.is_nil(credential.mechanism_properties, description)
        end
      else
        luassert.is_nil(credential, description)
        luassert.is_not_nil(err, description)
      end

      count = count + 1
    end
  end

  return count
end

function M.run_auth_002()
  return run_cases(AUTH_002_CASES)
end

function M.run_auth_003()
  return run_cases(AUTH_003_CASES)
end

return M
