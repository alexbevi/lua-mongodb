local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local retry_executor = require("mongodb.retry_executor")

describe("retryable read executor", function()
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
end)
