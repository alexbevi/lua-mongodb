local bson = require("mongodb.bson")
local sdam = require("mongodb.sdam")
local selection = require("mongodb.selection")

local FIXTURE_ROOT = (os.getenv("PWD") or ".")
  .. "/planning/specifications/source/"

local function number_value(value)
  if value == "NULL" then
    return nil
  end

  if type(value) == "number" then
    return value
  end

  if bson.is_exact(value) then
    return value:to_number()
  end

  return value
end

local function read_fixture(path)
  local file = assert(io.open(FIXTURE_ROOT .. path, "rb"))
  local content = file:read("*a")

  file:close()
  return assert(bson.json.decode(content))
end

local function fixture_paths(directory)
  local paths = {}
  local command = 'find "' .. FIXTURE_ROOT .. directory
    .. '" -type f -name "*.json" -print | sort'
  local process = assert(io.popen(command, "r"))

  for path in process:lines() do
    paths[#paths + 1] = path:sub(#FIXTURE_ROOT + 1)
  end

  assert(process:close())
  return paths
end

local function topology_type(name)
  for _, value in pairs(sdam.TOPOLOGY_TYPE) do
    if value == name then
      return value
    end
  end

  error("unknown fixture topology type: " .. tostring(name))
end

local function addresses_from(servers)
  local addresses = {}

  for index, server in servers:iter() do
    addresses[index] = server:get("address")
  end

  return addresses
end

local function hello_for(server, addresses, primary_address)
  local server_type = server:get("type")

  if server_type == "Unknown" or server_type == "PossiblePrimary" then
    return bson.document({})
  end

  local entries = {
    { "ok", 1 },
    { "maxWireVersion", server:get("maxWireVersion") or 21 },
  }

  if server_type == "LoadBalancer" then
    entries[#entries + 1] = {
      "serviceId",
      assert(bson.object_id("000000000000000000000001")),
    }
  elseif server_type == "Mongos" then
    entries[#entries + 1] = { "msg", "isdbgrid" }
  elseif server_type == "RSGhost" then
    entries[#entries + 1] = { "isreplicaset", true }
  elseif server_type:sub(1, 2) == "RS" then
    entries[#entries + 1] = { "setName", "fixture" }
    entries[#entries + 1] = { "hosts", bson.array(addresses) }

    if server_type == "RSPrimary" then
      entries[#entries + 1] = { "isWritablePrimary", true }
    elseif server_type == "RSSecondary" then
      entries[#entries + 1] = { "secondary", true }

      if primary_address then
        entries[#entries + 1] = { "primary", primary_address }
      end
    elseif server_type == "RSArbiter" then
      entries[#entries + 1] = { "arbiterOnly", true }
    elseif server_type == "RSOther" then
      entries[#entries + 1] = { "hidden", true }
    end
  end

  if server:get("tags") then
    entries[#entries + 1] = { "tags", server:get("tags") }
  end

  if server:get("lastWrite") then
    entries[#entries + 1] = { "lastWrite", server:get("lastWrite") }
  end

  return bson.document(entries)
end

local function topology_from_fixture(description)
  local servers = description:get("servers")
  local addresses = addresses_from(servers)
  local requested_type = topology_type(description:get("type"))
  local primary_address

  if #addresses == 0 then
    local topology = sdam.new({ seeds = { "empty-a:27017", "empty-b:27017" } })
    local standalone = bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "maxWireVersion", 21 },
    })

    topology = topology:update("empty-a:27017", standalone, { round_trip_time = 1 })
    topology = topology:update("empty-b:27017", standalone, { round_trip_time = 1 })
    assert.are.equal(requested_type, topology.type)
    assert.are.equal(0, #topology:addresses())
    return topology
  end

  for _, server in servers:iter() do
    if server:get("type") == "RSPrimary" then
      primary_address = server:get("address")
      break
    end
  end

  local options = {
    seeds = addresses,
    type = requested_type,
  }

  if requested_type == sdam.TOPOLOGY_TYPE.REPLICA_SET_NO_PRIMARY
      or requested_type == sdam.TOPOLOGY_TYPE.REPLICA_SET_WITH_PRIMARY
  then
    options.set_name = "fixture"
  end

  local topology = sdam.new(options)
  local ordered = {}

  for _, server in servers:iter() do
    if server:get("type") == "RSPrimary" then
      table.insert(ordered, 1, server)
    else
      ordered[#ordered + 1] = server
    end
  end

  for _, server in ipairs(ordered) do
    topology = topology:update(
      server:get("address"),
      hello_for(server, addresses, primary_address),
      {
        last_update_time = number_value(server:get("lastUpdateTime")),
        round_trip_time = number_value(server:get("avg_rtt_ms")),
      }
    )
  end

  assert.are.equal(requested_type, topology.type)
  return topology
end

local function expected_addresses(servers)
  local values = {}

  for _, server in servers:iter() do
    values[server:get("address")] = true
  end

  return values
end

local function assert_addresses(expected, actual, message)
  local remaining = expected_addresses(expected)

  assert.are.equal(#expected, #actual, message)

  for _, server in ipairs(actual) do
    assert.is_true(remaining[server.address], message .. ": unexpected " .. server.address)
    remaining[server.address] = nil
  end

  assert.is_nil(next(remaining), message)
end

local function deterministic_random(seed)
  local state = seed

  return function(limit)
    state = state * 48271 % 2147483647
    return state % limit + 1
  end
end

describe("server selection", function()
  it("ignores read preference for an available Single topology", function()
    local topology = sdam.new({
      seeds = { "a:27017" },
      type = sdam.TOPOLOGY_TYPE.SINGLE,
    }):update("a:27017", bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "maxWireVersion", 21 },
    }), { round_trip_time = 5 })

    local servers = assert(selection.candidates(topology, "read", {
      mode = "secondary_preferred",
    }))

    assert.are.equal(1, #servers)
    assert.are.equal("a:27017", servers[1].address)

    local preference = assert(selection.read_preference({ mode = "secondary" }))

    assert.has_error(function()
      preference.tag_sets[1].region = "east"
    end, "tag_set values are immutable")
  end)

  it("runs every production-core server-selection filtering fixture", function()
    local paths = fixture_paths("server-selection/tests/server_selection")
    local count = 0

    assert.are.equal(88, #paths)

    for _, path in ipairs(paths) do
      if not path:find("/LoadBalanced/", 1, true) then
        local fixture = read_fixture(path)
        local topology = topology_from_fixture(fixture:get("topology_description"))
        local result, err = selection.evaluate(
          topology,
          fixture:get("operation"),
          fixture:get("read_preference"),
          { deprioritized_servers = fixture:get("deprioritized_servers") }
        )

        assert.is_nil(err, path .. ": " .. tostring(err))
        assert_addresses(fixture:get("suitable_servers"), result.suitable_servers, path)
        assert_addresses(
          fixture:get("in_latency_window"),
          result.in_latency_window,
          path
        )
        count = count + 1
      end
    end

    assert.are.equal(78, count)
  end)

  it("runs every pinned max-staleness filtering fixture", function()
    local paths = fixture_paths("max-staleness/tests")

    assert.are.equal(32, #paths)

    for _, path in ipairs(paths) do
      local fixture = read_fixture(path)
      local topology = topology_from_fixture(fixture:get("topology_description"))
      local result, err = selection.evaluate(topology, "read", fixture:get("read_preference"), {
        heartbeat_frequency_ms = number_value(fixture:get("heartbeatFrequencyMS"))
          or 10000,
      })

      if fixture:get("error") == true then
        assert.is_nil(result, path)
        assert.is_not_nil(err, path)
      else
        assert.is_nil(err, path .. ": " .. tostring(err))
        assert_addresses(fixture:get("suitable_servers"), result.suitable_servers, path)
        assert_addresses(
          fixture:get("in_latency_window"),
          result.in_latency_window,
          path
        )
      end
    end
  end)

  it("runs every pinned RTT averaging fixture", function()
    local paths = fixture_paths("server-selection/tests/rtt")

    assert.are.equal(7, #paths)

    for _, path in ipairs(paths) do
      local fixture = read_fixture(path)
      local actual = selection.average_rtt(
        number_value(fixture:get("avg_rtt_ms")),
        number_value(fixture:get("new_rtt_ms"))
      )

      assert.near(number_value(fixture:get("new_avg_rtt")), actual, 0.0000001, path)
    end
  end)

  it("runs every pinned operation-count choice fixture", function()
    local paths = fixture_paths("server-selection/tests/in_window")

    assert.are.equal(8, #paths)

    for path_index, path in ipairs(paths) do
      local fixture = read_fixture(path)
      local topology = topology_from_fixture(fixture:get("topology_description"))
      local candidates = assert(selection.candidates(topology, "read", {
        mode = "nearest",
      }))
      local operation_counts = {}
      local selected_counts = {}

      for _, state in fixture:get("mocked_topology_state"):iter() do
        operation_counts[state:get("address")] = number_value(state:get("operation_count"))
      end

      local iterations = number_value(fixture:get("iterations"))
      local random = deterministic_random(path_index)

      for _ = 1, iterations do
        local server = selection.choose(candidates, {
          operation_counts = operation_counts,
          random = random,
        })

        selected_counts[server.address] = (selected_counts[server.address] or 0) + 1
      end

      local outcome = fixture:get("outcome")
      local tolerance = number_value(outcome:get("tolerance"))

      for address, expected in outcome:get("expected_frequencies"):iter() do
        local actual = (selected_counts[address] or 0) / iterations

        assert.is_true(
          math.abs(actual - number_value(expected)) <= tolerance,
          string.format("%s: %s expected %s, got %s", path, address, expected, actual)
        )
      end
    end
  end)

  it("composes a custom selector before applying the latency window", function()
    local topology = sdam.new({
      seeds = { "a:27017", "b:27017" },
      set_name = "fixture",
      type = sdam.TOPOLOGY_TYPE.REPLICA_SET_WITH_PRIMARY,
    })
    local hosts = bson.array({ "a:27017", "b:27017" })

    topology = topology:update("a:27017", bson.document({
      { "ok", 1 },
      { "setName", "fixture" },
      { "hosts", hosts },
      { "isWritablePrimary", true },
      { "maxWireVersion", 21 },
      { "lastWrite", bson.document({
        { "lastWriteDate", bson.datetime(100000) },
      }) },
    }), { last_update_time = 100000, round_trip_time = 5 })
    topology = topology:update("b:27017", bson.document({
      { "ok", 1 },
      { "setName", "fixture" },
      { "hosts", hosts },
      { "secondary", true },
      { "maxWireVersion", 21 },
      { "lastWrite", bson.document({
        { "lastWriteDate", bson.datetime(20000) },
      }) },
    }), { last_update_time = 100000, round_trip_time = 100 })

    local result = assert(selection.evaluate(topology, "read", {
      max_staleness_seconds = 90,
      mode = "nearest",
    }, {
      heartbeat_frequency_ms = 10000,
      selector = function(servers)
        return { servers[2] }
      end,
    }))

    assert.are.equal(1, #result.suitable_servers)
    assert.are.equal("b:27017", result.in_latency_window[1].address)
  end)

  it("reports the final topology when selection has no candidates", function()
    local topology = sdam.new({ seeds = { "a:27017" } })
    local server, err = selection.select(topology, "read", { mode = "primary" }, {
      timeout_ms = 125,
    })

    assert.is_nil(server)
    assert.are.equal("server_selection", err.category)
    assert.is_true(err.timeout)
    assert.are.equal("Unknown{a:27017=Unknown(server has not been checked)}", err.topology)
    assert.is_not_nil(err.message:find("final topology", 1, true))
  end)
end)
