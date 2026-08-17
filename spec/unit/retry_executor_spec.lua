local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local retry_executor = require("mongodb.retry_executor")
local operation_timeout = require("mongodb.operation_timeout")
local fake_runtime = require("mongodb.runtime.fake")

describe("retryable read executor", function()
  it("retries until the operation deadline under CSOT", function()
    local runtime = fake_runtime.new({ now = 0 })
    local calls = 0
    local underlying = {
      close = function() return true end,
      command = function()
        calls = calls + 1
        runtime:advance(0.004)
        return nil, errors.new({
          category = errors.CATEGORY.NETWORK,
          message = "connection closed",
        })
      end,
    }
    local executor = retry_executor.new(underlying)
    local result, err = operation_timeout.run(runtime, 10, {}, function(options)
      options.retryable_read = true
      return executor:command(
        "db",
        bson.document({ { "find", "items" } }),
        options
      )
    end)

    assert.is_nil(result)
    assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))
    assert.are.equal(3, calls)
  end)

  it("retries once with the same command and operation id", function()
    local calls = {}
    local underlying = {}

    function underlying.command(_, database, command, options)
      calls[#calls + 1] = {
        command = command,
        database = database,
        operation_id = options.operation_id,
      }

      if #calls == 1 then
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          code = 10107,
          message = "not writable primary",
        })
      end

      return bson.document({ { "ok", 1 } })
    end

    function underlying.close()
      return true
    end

    local executor = retry_executor.new(underlying, { enabled = true })
    local command = bson.document({
      { "find", "items" },
      { "lsid", bson.document({ { "id", "session" } }) },
    })
    local response = assert(executor:command(
      "db",
      command,
      { retryable_read = true }
    ))

    assert.are.equal(1, response:get("ok"))
    assert.are.equal(2, #calls)
    assert.are.equal(command, calls[1].command)
    assert.are.equal(command, calls[2].command)
    assert.are.equal(calls[1].operation_id, calls[2].operation_id)
  end)

  it("does not retry disabled, ineligible, or non-retryable commands", function()
    local calls = 0
    local underlying = {}

    function underlying.command()
      calls = calls + 1
      return nil, errors.new({
        category = errors.CATEGORY.SERVER,
        code = 2,
        message = "bad value",
      })
    end

    function underlying.close()
      return true
    end

    local executor = retry_executor.new(underlying, { enabled = true })
    local command = bson.document({ { "find", "items" } })

    assert.is_nil(executor:command("db", command, { retryable_read = true }))
    assert.are.equal(1, calls)
    assert.is_nil(executor:command("db", command))
    assert.are.equal(2, calls)

    executor = retry_executor.new(underlying, { enabled = false })
    assert.is_nil(executor:command("db", command, { retryable_read = true }))
    assert.are.equal(3, calls)
  end)

  it("returns the first error when retry server selection makes no attempt", function()
    local calls = 0
    local first = errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "connection closed",
      server = "a:27017",
    })
    local selection = errors.new({
      category = errors.CATEGORY.SERVER_SELECTION,
      message = "no server available",
    })
    local underlying = {}

    function underlying.command()
      calls = calls + 1
      return nil, calls == 1 and first or selection
    end

    function underlying.close()
      return true
    end

    local executor = retry_executor.new(underlying)
    local response, err = executor:command(
      "db",
      bson.document({ { "find", "items" } }),
      { retryable_read = true }
    )

    assert.is_nil(response)
    assert.are.equal(first, err)
    assert.are.equal(2, calls)
  end)

  it("deprioritizes an overloaded server for the retry", function()
    local calls = {}
    local underlying = {}

    function underlying.command(_, _, _, options)
      calls[#calls + 1] = options

      if #calls == 1 then
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          labels = { "SystemOverloadedError" },
          message = "overloaded",
          retryable = true,
          server = "a:27017",
        })
      end

      return bson.document({ { "ok", 1 } })
    end

    function underlying.close()
      return true
    end

    local executor = retry_executor.new(underlying)

    assert(executor:command(
      "db",
      bson.document({ { "find", "items" } }),
      { retryable_read = true }
    ))
    assert.is_nil(calls[1].deprioritized_servers)
    assert.same({ "a:27017" }, calls[2].deprioritized_servers)
  end)

  it("delegates capability discovery to the underlying executor", function()
    local capabilities = { max_wire_version = 25 }
    local executor = retry_executor.new({
      capabilities = function() return capabilities end,
      close = function() return true end,
      command = function() return bson.document({ { "ok", 1 } }) end,
    })

    assert.are.equal(capabilities, executor:capabilities())
  end)
end)

describe("retryable write executor", function()
  it("retries a retryable cleared-pool checkout error", function()
    local calls = 0
    local underlying = {
      close = function() return true end,
      command = function()
        calls = calls + 1

        if calls == 1 then
          return nil, errors.new({
            category = errors.CATEGORY.POOL,
            message = "connection pool is paused",
            retryable = true,
          })
        end

        return bson.document({ { "ok", 1 } })
      end,
    }
    local executor = retry_executor.new(underlying, { enabled_writes = true })

    assert(executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { retryable_write = true }
    ))
    assert.are.equal(2, calls)
  end)

  it("retries sanitized network and shutdown handshake failures", function()
    for _, first in ipairs({
      errors.new({
        category = errors.CATEGORY.AUTHENTICATION,
        message = "SCRAM network failure",
        retryable = true,
      }),
      errors.new({
        category = errors.CATEGORY.AUTHENTICATION,
        code = 91,
        message = "SCRAM shutdown failure",
      }),
    }) do
      local calls = 0
      local attempted_error
      local underlying = {}

      function underlying.command()
        calls = calls + 1

        if calls == 1 then
          return nil, first
        end

        return bson.document({ { "ok", 1 } })
      end

      function underlying.close()
        return true
      end

      local executor = retry_executor.new(underlying, { enabled_writes = true })

      assert(executor:command(
        "db",
        bson.document({ { "insert", "items" } }),
        {
          on_attempt_error = function(err)
            attempted_error = err
          end,
          retryable_write = true,
        }
      ))
      assert.are.equal(2, calls)
      assert.is_true(attempted_error:has_label("RetryableWriteError"))
    end
  end)

  it("retries once with one stable transaction number", function()
    local commands = {}
    local underlying = {}

    function underlying.command(_, _, command)
      commands[#commands + 1] = command

      if #commands == 1 then
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          labels = { "RetryableWriteError" },
          message = "retry write",
        })
      end

      return bson.document({ { "ok", 1 } })
    end

    function underlying.close()
      return true
    end

    local executor = retry_executor.new(underlying, {
      enabled_reads = true,
      enabled_writes = true,
    })
    local command = bson.document({
      { "insert", "items" },
      { "txnNumber", bson.int64(1) },
    })

    assert(executor:command("db", command, { retryable_write = true }))
    assert.are.equal(2, #commands)
    assert.are.equal(command, commands[1])
    assert.are.equal(command, commands[2])
    assert.are.equal(bson.int64(1), commands[2]:get("txnNumber"))
  end)

  it("retries a labelled write concern error and preserves attempted errors", function()
    local calls = 0
    local first = bson.document({
      { "ok", 1 },
      { "errorLabels", bson.array({ "RetryableWriteError" }) },
      { "writeConcernError", bson.document({
        { "code", 91 },
        { "errmsg", "shutdown" },
      }) },
    })
    local underlying = {}

    function underlying.command()
      calls = calls + 1

      if calls == 1 then
        return first
      end

      return nil, errors.new({
        category = errors.CATEGORY.POOL,
        message = "checkout failed",
      })
    end

    function underlying.close()
      return true
    end

    local executor = retry_executor.new(underlying, { enabled_writes = true })
    local response, err = executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { retryable_write = true }
    )

    assert.is_nil(response)
    assert.are.equal(91, err.code)
    assert.is_true(err:has_label("RetryableWriteError"))
    assert.are.equal(first, err.details.response)
  end)
end)
