local dns_discovery = require("mongodb.discovery.dns")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local uri = require("mongodb.config.uri")
local dns_seedlist_runner = require("spec.support.dns_seedlist_runner")
local client = require("mongodb.client")

describe("initial DNS seedlist discovery", function()
  it("resolves SRV and TXT before opening a MongoDB socket", function()
    local runtime = fake_runtime.new()

    runtime:queue_dns("srv", {
      {
        port = 27017,
        priority = 0,
        target = "db1.example.com",
        ttl = 60,
        weight = 5,
      },
    })
    runtime:queue_dns("txt", {
      { strings = { "replicaSet=", "rs0&authSource=admin" }, ttl = 120 },
    })

    local parsed = assert(uri.parse("mongodb+srv://cluster.example.com/app"))
    local resolved, config = assert(dns_discovery.resolve(parsed, {}, runtime))

    assert.are.same({
      { host = "db1.example.com", port = 27017, type = "hostname" },
    }, resolved.hosts)
    assert.are.equal("rs0", config.replica_set)
    assert.are.equal("admin", config.auth_source)
    assert.is_true(config.tls)
    assert.are.same({
      { name = "_mongodb._tcp.cluster.example.com", type = "srv" },
      { name = "cluster.example.com", type = "txt" },
    }, runtime.calls.dns)
    assert.are.same({}, runtime.calls.connect)
  end)

  it("rejects every returned target outside the source domain", function()
    local cases = {
      { source = "localhost", target = "localhost.mongodb" },
      { source = "mongo.local", target = "test_1.evil.local" },
      { source = "blogs.mongodb.com", target = "blogs.evil.com" },
      { source = "localhost", target = "localhost" },
      { source = "mongo.local", target = "mongo.local" },
      { source = "localhost", target = "test_1.cluster_1localhost" },
      { source = "mongo.local", target = "test_1.my_hostmongo.local" },
      { source = "blogs.mongodb.com", target = "cluster.testmongodb.com" },
    }

    for _, test in ipairs(cases) do
      local runtime = fake_runtime.new()

      runtime:queue_dns("srv", {
        { port = 27017, target = test.target, ttl = 60 },
      })

      local parsed = assert(uri.parse("mongodb+srv://" .. test.source))
      local resolved, err = dns_discovery.resolve(parsed, {}, runtime)

      assert.is_nil(resolved, test.source .. " -> " .. test.target)
      assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
      assert.are.same({}, runtime.calls.connect)
    end
  end)

  it("distinguishes empty SRV results and invalid TXT records", function()
    local cases = {
      { srv = {}, txt = {}, message = "SRV lookup returned no records" },
      {
        srv = { { port = 27017, target = "db.example.com", ttl = 60 } },
        txt = {
          { strings = { "replicaSet=rs0" }, ttl = 60 },
          { strings = { "authSource=admin" }, ttl = 60 },
        },
        message = "only one TXT record",
      },
      {
        srv = { { port = 27017, target = "db.example.com", ttl = 60 } },
        txt = { { strings = { "socketTimeoutMS=500" }, ttl = 60 } },
        message = "may contain only",
      },
      {
        srv = { { port = 27017, target = "db.example.com", ttl = 60 } },
        txt = { { strings = { "authSource" }, ttl = 60 } },
        message = "must contain '='",
      },
    }

    for _, test in ipairs(cases) do
      local runtime = fake_runtime.new()

      runtime:queue_dns("srv", test.srv)

      if #test.srv > 0 then
        runtime:queue_dns("txt", test.txt)
      end

      local parsed = assert(uri.parse("mongodb+srv://cluster.example.com"))
      local resolved, err = dns_discovery.resolve(parsed, {}, runtime)

      assert.is_nil(resolved)
      assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
      assert.matches(test.message, err.message, 1, true)
      assert.are.same({}, runtime.calls.connect)
    end
  end)

  it("applies explicit options above TXT defaults and samples srvMaxHosts", function()
    local runtime = fake_runtime.new()

    runtime:queue_dns("srv", {
      { port = 27017, target = "db1.example.com", ttl = 120 },
      { port = 27018, target = "db2.example.com", ttl = 60 },
      { port = 27019, target = "db3.example.com", ttl = 90 },
    })
    runtime:queue_dns("txt", {
      { strings = { "authSource=fromDns&loadBalanced=false" }, ttl = 60 },
    })

    local parsed = assert(uri.parse(
      "mongodb+srv://cluster.example.com/?srvMaxHosts=2&authSource=fromUri"
    ))
    local resolved, config = assert(dns_discovery.resolve(
      parsed,
      { auth_source = "fromCode" },
      runtime,
      { random = function(maximum) return maximum end }
    ))

    assert.are.equal(2, #resolved.hosts)
    assert.are.equal(60, resolved.srv.minimum_ttl)
    assert.are.equal("fromCode", config.auth_source)
    assert.is_false(config.load_balanced)
    assert.are.equal(2, config.srv_max_hosts)
  end)

  it("validates load-balanced TXT defaults after resolving both records", function()
    local cases = {
      {
        srv = {
          { port = 27017, target = "db1.example.com", ttl = 60 },
          { port = 27018, target = "db2.example.com", ttl = 60 },
        },
        uri = "mongodb+srv://cluster.example.com",
      },
      {
        srv = { { port = 27017, target = "db.example.com", ttl = 60 } },
        uri = "mongodb+srv://cluster.example.com/?replicaSet=rs0",
      },
    }

    for _, test in ipairs(cases) do
      local runtime = fake_runtime.new()

      runtime:queue_dns("srv", test.srv)
      runtime:queue_dns("txt", {
        { strings = { "loadBalanced=true" }, ttl = 60 },
      })

      local parsed = assert(uri.parse(test.uri))
      local resolved, err = dns_discovery.resolve(parsed, {}, runtime)

      assert.is_nil(resolved)
      assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
      assert.are.equal(2, #runtime.calls.dns)
      assert.are.same({}, runtime.calls.connect)
    end
  end)

  it("connects the load-balanced client after valid DNS preprocessing", function()
    local runtime = fake_runtime.new()

    runtime:queue_dns("srv", {
      { port = 27017, target = "db.example.com", ttl = 60 },
    })
    runtime:queue_dns("txt", {
      { strings = { "loadBalanced=true" }, ttl = 60 },
    })
    runtime:queue_connect(errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "expected load-balancer connection failure",
    }))

    local connected, err = client.connect(
      "mongodb+srv://cluster.example.com",
      { runtime = runtime }
    )

    assert.is_nil(connected)
    assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
    assert.are.same({ {
      host = "db.example.com",
      options = {},
      port = 27017,
    } }, runtime.calls.connect)
  end)

  it("does no DNS or socket work for an invalid SRV URI envelope", function()
    local runtime = fake_runtime.new()
    local parsed, err = uri.parse("mongodb+srv://one.example.com,two.example.com")

    assert.is_nil(parsed)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.same({}, runtime.calls.dns)
    assert.are.same({}, runtime.calls.connect)
  end)

  it("runs every pinned replica-set seedlist fixture", function()
    assert.are.equal(40, dns_seedlist_runner.run_replica_set_fixtures())
  end)

  it("runs every pinned load-balanced seedlist fixture", function()
    assert.are.equal(9, dns_seedlist_runner.run_load_balanced_fixtures())
  end)

  it("runs every pinned sharded srvMaxHosts fixture", function()
    assert.are.equal(4, dns_seedlist_runner.run_sharded_fixtures())
  end)
end)
