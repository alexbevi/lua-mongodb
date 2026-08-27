local copas = require("copas")
local errors = require("mongodb.error")
local runtime = require("mongodb.runtime")
local copas_runtime = require("mongodb.runtime.copas")

local function run_copas(callback)
  local outcome

  copas.loop(function()
    outcome = table.pack(pcall(callback))
  end)

  assert.is_table(outcome)

  if not outcome[1] then
    error(outcome[2], 0)
  end

  return table.unpack(outcome, 2, outcome.n)
end

describe("Copas runtime adapter", function()
  local function copas_with_version(version)
    return setmetatable({ _VERSION = version }, { __index = copas })
  end

  it("builds the validated public runtime", function()
    local adapter = runtime.copas()

    assert.are.equal(adapter, runtime.validate(adapter))
    assert.is_function(adapter.socket.connect)
    assert.is_true(adapter.process:identity() > 0)
    assert.is_table(adapter.metadata.environment)
    assert.is_boolean(adapter.metadata.files["/.dockerenv"])

    local facts = { environment = { VERCEL = "1" }, files = {} }
    local output = { write = function() return true end }
    local injected = runtime.copas({ metadata = facts, output = output })

    assert.are.equal(facts, injected.metadata)
    assert.are.equal(output, injected.output)
  end)

  it("reads process identity dynamically through an injected provider", function()
    local identity = 100
    local adapter = runtime.copas({
      getpid = function()
        return identity
      end,
    })

    assert.are.equal(100, adapter.process:identity())

    identity = 101

    assert.are.equal(101, adapter.process:identity())
  end)

  it("reads environment values dynamically through an injected provider", function()
    local values = { AWS_ACCESS_KEY_ID = "first" }
    local adapter = runtime.copas({
      getenv = function(name)
        return values[name]
      end,
      metadata = { environment = {}, files = {} },
    })

    assert.are.equal("first", adapter.environment:get("AWS_ACCESS_KEY_ID"))

    values.AWS_ACCESS_KEY_ID = "second"

    assert.are.equal("second", adapter.environment:get("AWS_ACCESS_KEY_ID"))
  end)

  it("writes process output through validated standard streams", function()
    local original_stdout = io.stdout
    local original_stderr = io.stderr
    local writes = {}
    local stream = {
      write = function(_, value, suffix)
        writes[#writes + 1] = { value, suffix }
        return true
      end,
    }
    local outcome = table.pack(pcall(function()
      rawset(io, "stdout", stream)
      rawset(io, "stderr", stream)

      local adapter = runtime.copas()

      assert.has_error(function()
        adapter.output:write("file", "entry")
      end, "output destination must be 'stdout' or 'stderr'")
      assert.has_error(function()
        adapter.output:write("stdout", {})
      end, "output value must be a string")
      assert(adapter.output:write("stdout", "first"))
      assert(adapter.output:write("stderr", "second"))

      rawset(io, "stdout", {
        write = function()
          return nil, "closed"
        end,
      })

      local written, err = adapter.output:write("stdout", "third")

      assert.is_nil(written)
      assert.is_true(errors.is(err, errors.CATEGORY.INTERNAL))
      assert.matches("closed", tostring(err), 1, true)
    end))

    rawset(io, "stdout", original_stdout)
    rawset(io, "stderr", original_stderr)

    if not outcome[1] then
      error(outcome[2], 0)
    end

    assert.are.same({
      { "first", "\n" },
      { "second", "\n" },
    }, writes)
  end)

  it("reads bounded files through the default adapter", function()
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))

    assert(file:write("token"))
    assert.is_true(file:close())

    local outcome = table.pack(pcall(function()
      local adapter = runtime.copas()

      assert.are.equal("token", assert(adapter.file:read(path, {
        max_bytes = 5,
      })))

      local value, err = adapter.file:read(path, { max_bytes = 4 })

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
    end))

    os.remove(path)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("accepts supported Copas versions", function()
    for _, version in ipairs({ "Copas 4.11.0", "Copas 4.12.0" }) do
      local adapter = copas_runtime.new({
        copas = copas_with_version(version),
      })

      assert.is_table(adapter)
    end
  end)

  it("rejects unsupported Copas versions", function()
    for _, version in ipairs({ "Copas 4.10.0", "Copas 4.13.0" }) do
      assert.has_error(function()
        copas_runtime.new({
          copas = copas_with_version(version),
        })
      end, "lua-mongodb requires Copas 4.11.x or 4.12.x")
    end
  end)

  it("clamps the exposed clock when its source moves backward", function()
    local values = { 10, 9, 11 }
    local index = 0
    local adapter = copas_runtime.new({
      gettime = function()
        index = index + 1
        return values[index]
      end,
    })

    assert.are.equal(10, adapter.clock:now())
    assert.are.equal(10, adapter.clock:now())
    assert.are.equal(11, adapter.clock:now())
  end)

  it("exposes an injected Unix wall clock separately", function()
    local adapter = copas_runtime.new({
      wall_time = function()
        return 1234567890
      end,
    })

    assert.are.equal(1234567890, adapter.clock:wall_time())
  end)

  it("spawns and awaits tasks with multiple results", function()
    local adapter = runtime.copas()

    run_copas(function()
      local started = false
      local task = adapter.task:spawn(function()
        started = true
        assert.is_true(adapter.clock:sleep(0.001))
        return 7, "seven"
      end)

      assert.are.equal("pending", task:status())
      assert.is_true(adapter.task:yield_control())
      assert.is_true(started)
      assert.are.equal("pending", task:status())

      local number, word = adapter.task:await(task)

      assert.are.equal(7, number)
      assert.are.equal("seven", word)
      assert.are.equal("completed", task:status())
    end)
  end)

  it("cancels pending tasks as structured operational failures", function()
    local adapter = runtime.copas()

    run_copas(function()
      local task = adapter.task:spawn(function()
        error("cancelled task must not run")
      end)

      assert.is_true(adapter.task:cancel(task, "client shutdown"))

      local value, err = adapter.task:await(task)

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))
      assert.are.equal("client shutdown", err.message)
      assert.are.equal("cancelled", task:status())
    end)
  end)

  it("wakes sleeping tasks when their token is cancelled", function()
    local adapter = runtime.copas()

    run_copas(function()
      local token = adapter.cancellation:new()
      local sleeper = adapter.task:spawn(function()
        return adapter.clock:sleep(1, token)
      end)

      adapter.task:spawn(function()
        adapter.clock:sleep(0.001)
        token:cancel("stop sleeping")
      end)

      local value, err = adapter.task:await(sleeper)

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))
      assert.are.equal("stop sleeping", err.message)
    end)
  end)

  it("serializes lock ownership between Copas tasks", function()
    local adapter = runtime.copas()

    run_copas(function()
      local lock = adapter.lock:new()
      local order = {}
      local first = adapter.task:spawn(function()
        assert.is_true(lock:acquire())
        order[#order + 1] = "first acquired"
        adapter.clock:sleep(0.002)
        order[#order + 1] = "first released"
        assert.is_true(lock:release())
      end)
      local second = adapter.task:spawn(function()
        assert.is_true(lock:acquire())
        order[#order + 1] = "second acquired"
        assert.is_true(lock:release())
      end)

      adapter.task:await(first)
      adapter.task:await(second)

      assert.are.same({
        "first acquired",
        "first released",
        "second acquired",
      }, order)
      assert.is_false(lock:is_locked())
    end)
  end)

  it("applies absolute deadlines while waiting for locks", function()
    local adapter = runtime.copas({ lock_poll_interval = 0.001 })

    run_copas(function()
      local lock = adapter.lock:new()

      assert.is_true(lock:acquire())

      local waiter = adapter.task:spawn(function()
        return lock:acquire(runtime.deadline_after(adapter, 0.003))
      end)
      local value, err = adapter.task:await(waiter)

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))
      assert.is_true(lock:release())
    end)
  end)

  it("applies cancellation while waiting for locks", function()
    local adapter = runtime.copas({ lock_poll_interval = 0.001 })

    run_copas(function()
      local lock = adapter.lock:new()
      local token = adapter.cancellation:new()

      assert.is_true(lock:acquire())

      local waiter = adapter.task:spawn(function()
        return lock:acquire(nil, token)
      end)

      adapter.task:spawn(function()
        adapter.clock:sleep(0.002)
        token:cancel("stop waiting")
      end)

      local value, err = adapter.task:await(waiter)

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))
      assert.are.equal("stop waiting", err.message)
      assert.is_true(lock:release())
    end)
  end)
end)
