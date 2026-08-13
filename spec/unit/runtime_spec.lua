local errors = require("mongodb.error")
local runtime = require("mongodb.runtime")
local fake_runtime = require("mongodb.runtime.fake")

describe("runtime interface", function()
  it("validates every required capability", function()
    local fake = fake_runtime.new()

    assert.are.equal(fake, runtime.validate(fake))
    assert.has_error(function()
      runtime.validate({})
    end, "runtime capability clock.now must be a function")
  end)

  it("uses absolute monotonic deadlines", function()
    local fake = fake_runtime.new({ now = 10, wall_time = 1000 })
    local deadline = runtime.deadline_after(fake, 5)

    assert.are.equal(15, deadline)
    assert.are.equal(5, runtime.remaining(fake, deadline))
    assert.is_true(fake.clock:sleep(2))
    assert.are.equal(12, fake.clock:now())
    assert.are.equal(1002, fake.clock:wall_time())
    assert.are.equal(3, runtime.remaining(fake, deadline))

    fake:advance(3)

    local ok, err = runtime.check(fake, deadline)

    assert.is_nil(ok)
    assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))
    assert.is_true(err.timeout)
    assert.are.equal(0, runtime.remaining(fake, deadline))
  end)

  it("propagates deterministic cancellation", function()
    local fake = fake_runtime.new()
    local token = fake.cancellation:new()
    local observed

    token:on_cancel(function(reason)
      observed = reason
    end)

    assert.is_true(token:cancel("client closed"))
    assert.is_false(token:cancel("ignored"))
    assert.is_true(token:is_cancelled())
    assert.are.equal("client closed", token:reason())
    assert.are.equal("client closed", observed)

    local ok, err = runtime.check(fake, nil, token)

    assert.is_nil(ok)
    assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))
    assert.are.equal("client closed", err.message)
  end)

  it("runs fake tasks in deterministic queue order", function()
    local fake = fake_runtime.new()
    local order = {}
    local first = fake.task:spawn(function()
      order[#order + 1] = "first"
      return 1, "one"
    end)
    local second = fake.task:spawn(function()
      order[#order + 1] = "second"
      return 2, "two"
    end)

    assert.are.equal("pending", first:status())
    assert.is_true(fake:run_next())
    assert.are.same({ "first" }, order)
    assert.are.equal("completed", first:status())

    local number, word = fake.task:await(second)

    assert.are.equal(2, number)
    assert.are.equal("two", word)
    assert.are.same({ "first", "second" }, order)
    assert.is_false(fake:run_next())
  end)

  it("provides deterministic cancellation for pending tasks", function()
    local fake = fake_runtime.new()
    local task = fake.task:spawn(function()
      error("must not run")
    end)

    assert.is_true(fake.task:cancel(task, "shutdown"))

    local value, err = fake.task:await(task)

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))
    assert.are.equal("shutdown", err.message)
    assert.is_false(fake:run_next())
  end)

  it("creates lock values with explicit ownership transitions", function()
    local fake = fake_runtime.new()
    local lock = fake.lock:new()

    assert.is_false(lock:is_locked())
    assert.is_true(lock:acquire())
    assert.is_true(lock:is_locked())
    assert.has_error(function()
      lock:acquire()
    end, "fake lock acquisition would block")
    assert.is_true(lock:release())
    assert.is_false(lock:is_locked())
    assert.has_error(function()
      lock:release()
    end, "cannot release an unlocked fake lock")
  end)

  it("scripts partial socket I/O and records writes", function()
    local fake = fake_runtime.new()
    local scripted_socket = fake.socket:new({ reads = { "ab", "cdef" }, max_write = 2 })

    fake:queue_connect(scripted_socket)

    local socket = assert(fake.socket:connect("db.example", 27017, { family = "unspecified" }))

    assert.are.equal("ab", socket:read_some(3))
    assert.are.equal("cde", socket:read_some(3))
    assert.are.equal("f", socket:read_some(3))
    assert.are.equal(2, socket:write_some("hello"))
    assert.are.same({ "he" }, socket:writes())
    assert.are.equal("db.example", fake.calls.connect[1].host)
    assert.are.equal(27017, fake.calls.connect[1].port)
    assert.is_true(socket:close())
    assert.is_false(socket:close())

    local value, err = socket:read_some(1)

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
  end)

  it("checks cancellation and deadlines before fake I/O", function()
    local fake = fake_runtime.new({ now = 5 })
    local scripted_socket = fake.socket:new({ reads = { "data" } })
    local token = fake.cancellation:new()

    token:cancel("cancelled read")

    local value, cancelled = scripted_socket:read_some(4, nil, token)

    assert.is_nil(value)
    assert.is_true(errors.is(cancelled, errors.CATEGORY.CANCELLED))

    value, cancelled = scripted_socket:read_some(4, 5)

    assert.is_nil(value)
    assert.is_true(errors.is(cancelled, errors.CATEGORY.TIMEOUT))
  end)

  it("scripts normalized DNS records with their TTLs", function()
    local fake = fake_runtime.new({ now = 5 })
    local expected = {
      {
        port = 27017,
        priority = 0,
        target = "db.example.com",
        ttl = 60,
        weight = 5,
      },
    }

    fake:queue_dns("srv", expected)

    local records = assert(fake.dns:resolve_srv("_mongodb._tcp.example.com"))

    assert.are.same(expected, records)
    assert.are.same({
      name = "_mongodb._tcp.example.com",
      type = "srv",
    }, fake.calls.dns[1])

    fake:queue_dns("txt", {
      { strings = { "replicaSet=", "rs0" }, ttl = 120 },
    })
    fake:queue_dns("txt", {})

    assert.are.same({
      { strings = { "replicaSet=", "rs0" }, ttl = 120 },
    }, assert(fake.dns:resolve_txt("example.com")))
    assert.are.same({}, assert(fake.dns:resolve_txt("missing.example.com")))

    local malformed = errors.new({
      category = errors.CATEGORY.PROTOCOL,
      message = "malformed DNS response",
    })

    fake:queue_dns("srv", malformed)

    local value, err = fake.dns:resolve_srv("_mongodb._tcp.example.com")

    assert.is_nil(value)
    assert.are.equal(malformed, err)

    local token = fake.cancellation:new()

    token:cancel("stop DNS")

    value, err = fake.dns:resolve_srv("example.com", nil, token)

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))

    value, err = fake.dns:resolve_srv("example.com", 5)

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))
  end)

  it("isolates TLS, entropy, and crypto capabilities", function()
    local fake = fake_runtime.new({ entropy = "abcdef" })
    local socket = fake.socket:new()

    assert.are.equal(socket, fake.tls:wrap(socket, { server_name = "db.example" }))
    assert.are.equal("db.example", fake.calls.tls[1].options.server_name)
    assert.are.equal("ab", fake.entropy:bytes(2))
    assert.are.equal("cde", fake.entropy:bytes(3))

    fake:queue_crypto("sha256", "digest")

    assert.are.equal("digest", fake.crypto:sha256("input"))
    assert.are.same({ "input" }, fake.calls.crypto[1].arguments)
  end)
end)
