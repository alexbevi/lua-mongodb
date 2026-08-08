local bson = require("mongodb.bson")
local sdam = require("mongodb.sdam")

local FIXTURE_ROOT = (os.getenv("PWD") or ".")
  .. "/planning/specifications/source/server-discovery-and-monitoring/tests/"

local function read_fixture(path)
  local file = assert(io.open(FIXTURE_ROOT .. path, "rb"))
  local content = file:read("*a")

  file:close()
  return assert(bson.json.decode(content))
end

local function fixture_paths()
  local paths = {}

  for _, directory in ipairs({ "single", "rs", "sharded" }) do
    local command = 'find "' .. FIXTURE_ROOT .. directory
      .. '" -maxdepth 1 -type f -name "*.json" -print | sort'
    local process = assert(io.popen(command, "r"))

    for path in process:lines() do
      paths[#paths + 1] = directory .. "/" .. path:match("([^/]+)$")
    end

    assert(process:close())
  end

  return paths
end


local function number_value(value)
  if type(value) == "number" then
    return value
  end

  if bson.is_exact(value) then
    return value:to_number()
  end
end

local function expected_value(document, name)
  local value = document:get(name)

  if value == nil then
    return false
  elseif bson.is_null(value) then
    return true, nil
  end

  return true, value
end

local function assert_topology_version(expected, actual, message)
  if expected == nil then
    assert.is_nil(actual, message)
    return
  end

  assert.is_true(bson.is_document(actual), message)
  assert.are.equal(expected:get("processId"), actual:get("processId"), message)
  assert.are.equal(
    number_value(expected:get("counter")),
    number_value(actual:get("counter")),
    message
  )
end

local function assert_server(expected, actual, message)
  assert.is_not_nil(actual, message)
  assert.are.equal(expected:get("type"), actual.type, message)

  for expected_name, actual_name in pairs({
    electionId = "election_id",
    logicalSessionTimeoutMinutes = "logical_session_timeout_minutes",
    maxWireVersion = "max_wire_version",
    minWireVersion = "min_wire_version",
    setName = "set_name",
    setVersion = "set_version",
  }) do
    local present, value = expected_value(expected, expected_name)

    if present then
      assert.are.equal(number_value(value) or value, actual[actual_name], message)
    end
  end

  local error_present, error_substring = expected_value(expected, "error")

  if error_present then
    assert.is_not_nil(actual.error, message)
    assert.is_not_nil(tostring(actual.error):find(error_substring, 1, true), message)
  end

  local version_present, version = expected_value(expected, "topologyVersion")

  if version_present then
    assert_topology_version(version, actual.topology_version, message)
  end
end

local function assert_outcome(expected, topology, message)
  assert.are.equal(expected:get("topologyType"), topology.type, message)
  local servers = expected:get("servers")

  assert.are.equal(#servers, #topology:addresses(), message)

  for address, expected_server in servers:iter() do
    assert_server(expected_server, topology:server(address), message .. ": " .. address)
  end

  for expected_name, actual_name in pairs({
    logicalSessionTimeoutMinutes = "logical_session_timeout_minutes",
    maxElectionId = "max_election_id",
    maxSetVersion = "max_set_version",
    setName = "set_name",
  }) do
    local present, value = expected_value(expected, expected_name)

    if present then
      assert.are.equal(number_value(value) or value, topology[actual_name], message)
    end
  end

  local compatible_present, compatible = expected_value(expected, "compatible")

  if compatible_present then
    assert.are.equal(compatible, topology.compatible, message)
  end
end

describe("SDAM description transitions", function()
  it("runs the standalone discovery phase fixture", function()
    local fixture = read_fixture("single/discover_standalone.json")
    local topology = assert(sdam.from_uri(fixture:get("uri")))
    local phase = fixture:get("phases"):get(1)
    local response = phase:get("responses"):get(1)

    topology = assert(topology:update(response:get(1), response:get(2)))

    assert.are.equal("Single", topology.type)
    assert.are.equal("Standalone", topology:server("a:27017").type)
    assert.has_error(function()
      topology.type = "Unknown"
    end, "topology descriptions are immutable")
  end)

  it("runs every pinned phase-one topology transition fixture", function()
    local count = 0

    for _, path in ipairs(fixture_paths()) do
      local fixture = read_fixture(path)
      local topology = assert(sdam.from_uri(fixture:get("uri")))

      for phase_index, phase in fixture:get("phases"):iter() do
        local responses = phase:get("responses")

        if bson.is_array(responses) then
          for _, response in responses:iter() do
            topology = assert(topology:update(response:get(1), response:get(2)))
          end
        end

        local message = path .. " phase " .. phase_index

        assert_outcome(phase:get("outcome"), topology, message)
        count = count + 1
      end
    end

    assert.is_true(count > 100)
  end)

  it("ignores stale generations without mutating prior descriptions", function()
    local topology = sdam.new({ seeds = { "a:27017" } })
    local hello = bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "maxWireVersion", 21 },
    })
    local known = topology:update("a:27017", hello, { generation = 2 })
    local ignored = known:update("a:27017", bson.document({}), { generation = 1 })

    assert.are.equal(known, ignored)
    assert.are.equal("Standalone", known:server("a:27017").type)
    assert.are.equal("Unknown", topology:server("a:27017").type)
    assert.has_error(function()
      known:server("a:27017").type = "Unknown"
    end, "server descriptions are immutable")
  end)

  it("replaces RTT fields without mutating the prior description", function()
    local topology = sdam.new({ seeds = { "a:27017" } })
    local updated = topology:with_round_trip_times("A:27017", 12.5, 4.25)

    assert.is_nil(topology:server("a:27017").round_trip_time)
    assert.are.equal(12.5, updated:server("a:27017").round_trip_time)
    assert.are.equal(4.25, updated:server("a:27017").minimum_round_trip_time)
    assert.has_error(function()
      updated:with_round_trip_times("a:27017", -1, 0)
    end, "average round trip time must be a finite non-negative number")
    assert.has_error(function()
      updated:with_round_trip_times("b:27017", 1, 1)
    end, "round trip time address is not in the topology")
  end)

  it("compares server descriptions by their SDAM fields", function()
    local first = sdam.server_description("A", bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "hosts", bson.array({ "a:27017" }) },
      { "tags", bson.document({ { "region", "east" } }) },
      { "maxWireVersion", 21 },
    }))
    local same = sdam.server_description("a:27017", bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "hosts", bson.array({ "a:27017" }) },
      { "tags", bson.document({ { "region", "east" } }) },
      { "maxWireVersion", 21 },
    }))
    local different = sdam.server_description("a:27017", bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "hosts", bson.array({ "b:27017" }) },
      { "tags", bson.document({ { "region", "east" } }) },
      { "maxWireVersion", 21 },
    }))

    assert.is_true(first:equals(same))
    assert.is_false(first:equals(different))
  end)
end)
