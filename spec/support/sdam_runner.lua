local bson = require("mongodb.bson")
local fake_runtime = require("mongodb.runtime.fake")
local sdam = require("mongodb.sdam")
local topology = require("mongodb.topology")

local M = {}

local FIXTURE_ROOT = (os.getenv("PWD") or ".")
  .. "/planning/specifications/source/server-discovery-and-monitoring/tests/"

local EVENT_TYPES = {
  server_closed_event = "ServerClosed",
  server_description_changed_event = "ServerDescriptionChanged",
  server_opening_event = "ServerOpening",
  topology_closed_event = "TopologyClosed",
  topology_description_changed_event = "TopologyDescriptionChanged",
  topology_opening_event = "TopologyOpening",
}

local function fail(message)
  error(message, 3)
end

local function require_equal(expected, actual, message)
  if expected ~= actual then
    fail(string.format("%s: expected %s, got %s", message, expected, actual))
  end
end

local function require_value(value, message)
  if value == nil then
    fail(message .. ": expected a value")
  end
end

local function read_fixture(path)
  local file = assert(io.open(FIXTURE_ROOT .. path, "rb"))
  local content = file:read("*a")

  file:close()
  return assert(bson.json.decode(content))
end

local function number_value(value)
  if type(value) == "number" then
    return value
  elseif bson.is_exact(value) then
    return value:to_number()
  end

  return value
end

local function expected_value(document, name)
  local value = document:get(name)

  if value == nil then
    return false
  elseif bson.is_null(value) then
    return true, nil
  end

  return true, number_value(value)
end

local function assert_array(expected, actual, message)
  require_value(actual, message)
  require_equal(#expected, #actual, message .. " length")

  for index, value in expected:iter() do
    require_equal(value, actual[index], message .. " item " .. index)
  end
end

local function assert_topology_version(expected, actual, message)
  if expected == nil then
    require_equal(nil, actual, message)
    return
  end

  require_value(actual, message)
  require_equal(expected:get("processId"), actual:get("processId"), message)
  require_equal(
    number_value(expected:get("counter")),
    number_value(actual:get("counter")),
    message
  )
end

local function assert_server(expected, actual, message)
  require_value(actual, message)

  for expected_name, actual_name in pairs({
    address = "address",
    electionId = "election_id",
    logicalSessionTimeoutMinutes = "logical_session_timeout_minutes",
    maxWireVersion = "max_wire_version",
    minWireVersion = "min_wire_version",
    primary = "primary",
    setName = "set_name",
    setVersion = "set_version",
    type = "type",
  }) do
    local present, value = expected_value(expected, expected_name)

    if present then
      require_equal(value, actual[actual_name], message .. "." .. expected_name)
    end
  end

  for expected_name, actual_name in pairs({
    arbiters = "arbiters",
    hosts = "hosts",
    passives = "passives",
  }) do
    local value = expected:get(expected_name)

    if bson.is_array(value) then
      assert_array(value, actual[actual_name], message .. "." .. expected_name)
    end
  end

  local present, version = expected_value(expected, "topologyVersion")

  if present then
    assert_topology_version(version, actual.topology_version, message .. ".topologyVersion")
  end
end

local function assert_topology(expected, actual, message)
  local expected_type = expected:get("topologyType")

  if actual == nil then
    require_equal("Unknown", expected_type, message .. ".topologyType")
    local servers = expected:get("servers")

    require_equal(0, #servers, message .. ".servers")
    return
  end

  require_equal(expected_type, actual.type, message .. ".topologyType")

  for expected_name, actual_name in pairs({
    logicalSessionTimeoutMinutes = "logical_session_timeout_minutes",
    maxElectionId = "max_election_id",
    maxSetVersion = "max_set_version",
    setName = "set_name",
  }) do
    local present, value = expected_value(expected, expected_name)

    if present then
      require_equal(value, actual[actual_name], message .. "." .. expected_name)
    end
  end

  local expected_servers = expected:get("servers")

  if bson.is_document(expected_servers) then
    require_equal(#expected_servers, #actual:addresses(), message .. ".servers")

    for address, expected_server in expected_servers:iter() do
      assert_server(expected_server, actual:server(address), message .. "." .. address)
    end
  elseif bson.is_array(expected_servers) then
    require_equal(#expected_servers, #actual:addresses(), message .. ".servers")

    for _, expected_server in expected_servers:iter() do
      local address = expected_server:get("address")

      assert_server(expected_server, actual:server(address), message .. "." .. address)
    end
  end
end

local function new_pool()
  local value = {
    generation = 0,
    operation_count = 0,
    state = "paused",
  }

  function value:ready()
    self.state = "ready"
    return true
  end

  function value:clear()
    self.generation = self.generation + 1
    self.state = "paused"
    return true
  end

  function value:close()
    self.state = "closed"
    return true
  end

  return value
end

local function fixture_manager(fixture)
  local description = assert(sdam.from_uri(fixture:get("uri")))
  local events = {}
  local pools = {}
  local runtime = fake_runtime.new()
  local manager = topology.new({
    listeners = {
      function(event)
        if not event.type:find("Heartbeat", 1, true) then
          events[#events + 1] = event
        end
      end,
    },
    pool_factory = function(address)
      local value = new_pool()

      pools[address] = value
      return value
    end,
    runtime = runtime,
    seeds = description:addresses(),
    set_name = description.set_name,
    topology_id = "42",
    type = description.type,
  })

  assert(manager:open({ background = false }))
  return manager, events, pools
end

local function assert_event(expected, actual, message)
  local expected_name, expected_fields = expected:iter()()

  require_equal(EVENT_TYPES[expected_name], actual.type, message .. ".type")

  for name, value in expected_fields:iter() do
    if name == "topologyId" then
      require_equal(value, actual.topology_id, message .. ".topologyId")
    elseif name == "address" then
      require_equal(value, actual.address, message .. ".address")
    elseif name == "previousDescription" then
      if expected_name == "server_description_changed_event" then
        assert_server(value, actual.previous_description, message .. ".previousDescription")
      else
        assert_topology(value, actual.previous_description, message .. ".previousDescription")
      end
    elseif name == "newDescription" then
      if expected_name == "server_description_changed_event" then
        assert_server(value, actual.new_description, message .. ".newDescription")
      else
        assert_topology(value, actual.new_description, message .. ".newDescription")
      end
    else
      fail(message .. ": unknown expected SDAM event field " .. name)
    end
  end
end

local function assert_events(expected, actual, message)
  require_equal(#expected, #actual, message .. " event count")

  for index, event in expected:iter() do
    assert_event(event, actual[index], message .. " event " .. index)
  end
end

local function assert_outcome(expected, manager, pools, message)
  assert_topology(expected, manager.description, message)
  local servers = expected:get("servers")

  for address, server in servers:iter() do
    local expected_pool = server:get("pool")

    if bson.is_document(expected_pool) then
      require_value(pools[address], message .. "." .. address .. ".pool")
      require_equal(
        number_value(expected_pool:get("generation")),
        pools[address].generation,
        message .. "." .. address .. ".pool.generation"
      )
    end
  end
end

local function application_error(document)
  local fields = {
    generation = number_value(document:get("generation")),
    max_wire_version = number_value(document:get("maxWireVersion")),
    response = document:get("response"),
    type = document:get("type"),
    when = document:get("when"),
  }

  return fields
end

function M.run(path)
  local fixture = read_fixture(path)
  local manager, events, pools = fixture_manager(fixture)

  for phase_index, phase in fixture:get("phases"):iter() do
    local responses = phase:get("responses")

    if bson.is_array(responses) then
      for _, response in responses:iter() do
        manager:process_hello(response:get(1), response:get(2), { duration = 0.001 })
      end
    end

    local application_errors = phase:get("applicationErrors")

    if bson.is_array(application_errors) then
      for _, item in application_errors:iter() do
        manager:handle_application_error(item:get("address"), application_error(item))
      end
    end

    local outcome = phase:get("outcome")
    local message = path .. " phase " .. phase_index
    local expected_events = outcome:get("events")

    if bson.is_array(expected_events) then
      assert_events(expected_events, events, message)

      for index = #events, 1, -1 do
        events[index] = nil
      end
    else
      assert_outcome(outcome, manager, pools, message)
    end
  end

  manager:close()
  return true
end

function M.fixture_paths(directory)
  local paths = {}
  local command = 'find "' .. FIXTURE_ROOT .. directory
    .. '" -maxdepth 1 -type f -name "*.json" -print | sort'
  local process = assert(io.popen(command, "r"))

  for path in process:lines() do
    paths[#paths + 1] = directory .. "/" .. path:match("([^/]+)$")
  end

  assert(process:close())
  return paths
end

return M
