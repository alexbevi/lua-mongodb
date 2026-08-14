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
local AUTH_004_CASES = {
  [16] = true,
  [17] = true,
  [18] = true,
  [19] = true,
  [20] = true,
  [21] = true,
  [22] = true,
}
local AUTH_020_CASES = {
  [40] = true,
  [41] = true,
  [42] = true,
  [43] = true,
  [44] = true,
  [45] = true,
  [46] = true,
  [47] = true,
}
local AUTH_020_SUPERSEDED = {
  [43] = true,
  [44] = true,
}
local AUTH_010_CASES = {
  [48] = true,
  [49] = true,
  [50] = true,
  [51] = true,
  [52] = true,
  [53] = true,
  [54] = true,
  [55] = true,
  [56] = true,
  [57] = true,
  [58] = true,
  [59] = true,
  [60] = true,
  [61] = true,
  [62] = true,
  [63] = true,
  [64] = true,
  [65] = true,
  [66] = true,
  [67] = true,
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

local function assert_mechanism_properties(expected, actual, description)
  if expected == nil or bson.is_null(expected) then
    luassert.is_nil(actual, description .. ": mechanism_properties")
    return
  end

  luassert.is_table(actual, description .. ": mechanism_properties")

  local expected_count = 0

  for name in expected:iter() do
    luassert.are.equal(
      expected_value(expected, name),
      actual[name],
      description .. ": mechanism_properties." .. name
    )
    expected_count = expected_count + 1
  end

  local actual_count = 0

  for _ in pairs(actual) do
    actual_count = actual_count + 1
  end

  luassert.are.equal(
    expected_count,
    actual_count,
    description .. ": mechanism_properties count"
  )
end

local function run_cases(cases, superseded)
  local count = 0
  local superseded_count = 0

  for index, test in load_fixture():get("tests"):iter() do
    if cases[index] then
      local description = test:get("description")
      local credential, err = normalize(test:get("uri"))
      local expected_valid = test:get("valid")

      if superseded and superseded[index] then
        expected_valid = false
        superseded_count = superseded_count + 1
      end

      assert((credential ~= nil or err == nil) == expected_valid, description)

      if expected_valid then
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

          assert_mechanism_properties(
            expected:get("mechanism_properties"),
            credential.mechanism_properties,
            description
          )
        end
      else
        luassert.is_nil(credential, description)
        luassert.is_not_nil(err, description)
      end

      count = count + 1
    end
  end

  return count, superseded_count
end

function M.run_auth_002()
  return run_cases(AUTH_002_CASES)
end

function M.run_auth_003()
  return run_cases(AUTH_003_CASES)
end

function M.run_auth_004()
  return run_cases(AUTH_004_CASES)
end

function M.run_auth_020()
  local count, superseded = run_cases(AUTH_020_CASES, AUTH_020_SUPERSEDED)

  return {
    executed = count,
    passed = count - superseded,
    superseded = superseded,
  }
end

function M.run_auth_010()
  return run_cases(AUTH_010_CASES)
end

return M
