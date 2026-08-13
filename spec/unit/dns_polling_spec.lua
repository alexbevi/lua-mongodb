local bson = require("mongodb.bson")
local dns_polling_runner = require("spec.support.dns_polling_runner")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local topology = require("mongodb.topology")

describe("SRV topology polling", function()
  it("reconciles an Unknown topology without replacing unchanged servers", function()
    local runtime = fake_runtime.new()
    local manager = topology.new({
      runtime = runtime,
      seeds = { "a.example.com:27017", "b.example.com:27017" },
      srv = {
        hostname = "cluster.example.com",
        max_hosts = 0,
        minimum_ttl = 30,
        service_name = "mongodb",
      },
      type = "Unknown",
    })

    assert(manager:open({ background = false }))
    local unchanged = manager.description:server("a.example.com:27017")

    runtime:queue_dns("srv", {
      { port = 27017, target = "a.example.com", ttl = 120 },
      { port = 27018, target = "c.example.com", ttl = 45 },
    })

    assert(manager:rescan_srv())
    assert.are.same({ "a.example.com:27017", "c.example.com:27018" },
      manager.description:addresses())
    assert.are.equal(unchanged,
      manager.description:server("a.example.com:27017"))
    assert.are.equal("Unknown",
      manager.description:server("c.example.com:27018").type)
    assert.are.equal(60000, manager.srv_rescan_interval_ms)
    assert(manager:close())
  end)

  it("runs all thirteen normative polling prose cases", function()
    assert.are.equal(13, dns_polling_runner.run_prose_cases())
  end)

  it("ignores invalid SRV targets and preserves the topology if none are valid", function()
    local runtime = fake_runtime.new()
    local manager = topology.new({
      heartbeat_frequency_ms = 5000,
      runtime = runtime,
      seeds = { "a.example.com:27017" },
      srv = {
        hostname = "cluster.example.com",
        max_hosts = 0,
        minimum_ttl = 120,
        service_name = "mongodb",
      },
      type = "Sharded",
    })

    assert(manager:open({ background = false }))
    local before = manager.description

    runtime:queue_dns("srv", {
      { port = 27017, target = "outside.invalid", ttl = 60 },
    })
    assert(manager:rescan_srv())
    assert.are.equal(before, manager.description)
    assert.are.equal(5000, manager.srv_rescan_interval_ms)
    assert.are.same({}, runtime.calls.connect)
    assert(manager:close())
  end)

  it("uses the lowest successful TTL above the sixty-second floor", function()
    local runtime = fake_runtime.new()
    local manager = topology.new({
      runtime = runtime,
      seeds = { "a.example.com:27017" },
      srv = {
        hostname = "cluster.example.com",
        max_hosts = 0,
        minimum_ttl = 30,
        service_name = "mongodb",
      },
      type = "Unknown",
    })

    assert(manager:open({ background = false }))
    runtime:queue_dns("srv", {
      { port = 27017, target = "a.example.com", ttl = 180 },
      { port = 27018, target = "b.example.com", ttl = 120 },
    })
    assert(manager:rescan_srv())
    assert.are.equal(120000, manager.srv_rescan_interval_ms)
    assert(manager:close())
  end)

  it("stops polling replica-set, Single, load-balanced, and closed topologies", function()
    for _, topology_type in ipairs({
      "Single",
      "ReplicaSetNoPrimary",
      "ReplicaSetWithPrimary",
      "LoadBalanced",
    }) do
      local runtime = fake_runtime.new()
      local manager = topology.new({
        runtime = runtime,
        seeds = { "a.example.com:27017" },
        srv = {
          hostname = "cluster.example.com",
          max_hosts = 0,
          minimum_ttl = 60,
          service_name = "mongodb",
        },
        type = topology_type,
      })

      assert(manager:open({ background = false }))
      assert.is_false(manager:rescan_srv(), topology_type)
      assert.are.same({}, runtime.calls.dns, topology_type)
      assert(manager:close())
      assert.is_false(manager:rescan_srv(), topology_type .. " closed")
    end
  end)

  it("stops polling when Unknown becomes a replica-set topology", function()
    local runtime = fake_runtime.new()
    local manager = topology.new({
      runtime = runtime,
      seeds = { "a.example.com:27017" },
      srv = {
        hostname = "cluster.example.com",
        max_hosts = 0,
        minimum_ttl = 60,
        service_name = "mongodb",
      },
      type = "Unknown",
    })

    assert(manager:open({ background = false }))
    assert(manager:process_hello("a.example.com:27017", bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "setName", "rs0" },
      { "hosts", bson.array({ "a.example.com:27017" }) },
      { "maxWireVersion", 25 },
    })))

    assert.are.equal("ReplicaSetWithPrimary", manager.description.type)
    assert.is_false(manager:rescan_srv())
    assert.are.same({}, runtime.calls.dns)
    assert(manager:close())
  end)

  it("keeps operational DNS failures internal and retries at heartbeat cadence", function()
    local runtime = fake_runtime.new()
    local manager = topology.new({
      heartbeat_frequency_ms = 7000,
      runtime = runtime,
      seeds = { "a.example.com:27017" },
      srv = {
        hostname = "cluster.example.com",
        max_hosts = 0,
        minimum_ttl = 120,
        service_name = "mongodb",
      },
      type = "Sharded",
    })

    assert(manager:open({ background = false }))
    runtime:queue_dns("srv", errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "temporary DNS failure",
    }))

    assert(manager:rescan_srv())
    assert.are.same({ "a.example.com:27017" }, manager.description:addresses())
    assert.are.equal(7000, manager.srv_rescan_interval_ms)
    assert(manager:close())
  end)
end)
