local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local luassert = require("luassert")
local topology = require("mongodb.topology")

local M = {}

local HOST = "localhost.test.build.10gen.cc"

local function addresses(ports)
  local result = {}

  for index, port in ipairs(ports) do
    result[index] = HOST .. ":" .. tostring(port)
  end

  table.sort(result)
  return result
end

local function records(ports)
  local result = {}

  for index, port in ipairs(ports) do
    result[index] = {
      port = port,
      priority = 0,
      target = HOST,
      ttl = 86400,
      weight = 0,
    }
  end

  return result
end

local function new_manager(runtime, ports, options)
  options = options or {}
  local manager = topology.new({
    heartbeat_frequency_ms = 10000,
    runtime = runtime,
    seeds = addresses(ports),
    srv = {
      hostname = options.hostname or "test1.test.build.10gen.cc",
      max_hosts = options.max_hosts or 0,
      minimum_ttl = 86400,
      random = function(maximum) return maximum end,
      service_name = options.service_name or "mongodb",
    },
    type = options.type or "Sharded",
  })

  luassert(manager:open({ background = false }))
  return manager
end

local function assert_change(initial, returned, expected, options)
  local runtime = fake_runtime.new()
  local manager = new_manager(runtime, initial, options)

  runtime:queue_dns("srv", records(returned))
  luassert(manager:rescan_srv())
  luassert.same(addresses(expected), manager.description:addresses())
  luassert(manager:close())
  return runtime
end

local function assert_unchanged(result)
  local runtime = fake_runtime.new()
  local manager = new_manager(runtime, { 27017, 27018 })
  local before = manager.description

  runtime:queue_dns("srv", result)
  luassert(manager:rescan_srv())
  luassert.equal(before, manager.description)
  luassert.equal(10000, manager.srv_rescan_interval_ms)
  luassert(manager:close())
end

function M.run_prose_cases()
  local count = 0
  local function run(callback)
    callback()
    count = count + 1
  end

  run(function()
    assert_change({ 27017, 27018 }, { 27017, 27018, 27019 },
      { 27017, 27018, 27019 })
  end)
  run(function()
    assert_change({ 27017, 27018 }, { 27017 }, { 27017 })
  end)
  run(function()
    assert_change({ 27017, 27018 }, { 27017, 27019 }, { 27017, 27019 })
  end)
  run(function()
    assert_change({ 27017, 27018 }, { 27019 }, { 27019 })
  end)
  run(function()
    assert_change({ 27017, 27018 }, { 27019, 27020 }, { 27019, 27020 })
  end)
  run(function()
    assert_unchanged(errors.new({
      category = errors.CATEGORY.TIMEOUT,
      message = "DNS lookup timed out",
    }))
  end)
  run(function()
    assert_unchanged(errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "DNS name does not exist",
    }))
  end)
  run(function()
    assert_unchanged({})
  end)
  run(function()
    local runtime = fake_runtime.new()
    local manager = new_manager(runtime, { 27017 }, {
      hostname = "test3.test.build.10gen.cc",
      type = "LoadBalanced",
    })

    luassert.is_false(manager:rescan_srv())
    luassert.same({}, runtime.calls.dns)
    luassert(manager:close())
  end)
  run(function()
    assert_change({ 27017, 27018 }, { 27017, 27019, 27020 },
      { 27017, 27019, 27020 }, { max_hosts = 0 })
  end)
  run(function()
    assert_change({ 27017, 27018 }, { 27019, 27020 },
      { 27019, 27020 }, { max_hosts = 2 })
  end)
  run(function()
    assert_change({ 27017, 27018 }, { 27017, 27019, 27020 },
      { 27017, 27019 }, { max_hosts = 2 })
  end)
  run(function()
    local runtime = assert_change({ 27017 }, { 27019, 27020 },
      { 27019, 27020 }, {
        hostname = "test22.test.build.10gen.cc",
        service_name = "customname",
      })

    luassert.equal(
      "_customname._tcp.test22.test.build.10gen.cc",
      runtime.calls.dns[1].name
    )
  end)

  return count
end

return M
