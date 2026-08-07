local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local api = require("mongodb.api")
local driver_options = require("mongodb.config.options")
local retry_executor = require("mongodb.retry_executor")
local session_module = require("mongodb.session")
local session_executor = require("mongodb.session_executor")

local function identifiers()
  local next_id = 0

  return function()
    next_id = next_id + 1
    return bson.document({
      { "id", bson.binary(
        string.rep(string.char(next_id), 16),
        bson.BINARY_SUBTYPE.UUID
      ) },
    })
  end
end

describe("client sessions", function()
  it("decorates causal commands and rejects an ended session", function()
    local identifier = bson.document({
      { "id", bson.binary(string.rep("s", 16), bson.BINARY_SUBTYPE.UUID) },
    })
    local sessions = session_module.new({
      id_factory = function()
        return identifier
      end,
      timeout_minutes = 30,
    })
    local session = assert(sessions:start({ causal_consistency = true }))
    local operation_time = bson.timestamp(4, 2)

    assert(session:advance_operation_time(operation_time))
    local command = assert(sessions:decorate(
      bson.document({ { "find", "items" } }),
      { read_concern = bson.document({}), session = session }
    ))

    assert.are.equal(identifier, command:get("lsid"))
    assert.are.equal(
      operation_time,
      command:get("readConcern"):get("afterClusterTime")
    )
    assert(session:end_session())

    local decorated, err = sessions:decorate(
      bson.document({ { "find", "items" } }),
      { session = session }
    )

    assert.is_nil(decorated)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
  end)

  it("reuses clean server sessions and discards dirty sessions", function()
    local sessions = session_module.new({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local first = assert(sessions:start())
    local first_lsid = assert(first:get_lsid())

    assert(first:end_session())
    local reused = assert(sessions:start())

    assert.are.equal(first_lsid, assert(reused:get_lsid()))
    assert(reused:mark_dirty())
    assert(reused:end_session())
    local replacement = assert(sessions:start())

    assert.are_not.equal(first_lsid, assert(replacement:get_lsid()))
  end)

  it("advances causal time and retains an implicit session for a cursor", function()
    local calls = {}
    local underlying = {}

    function underlying.command(_, database, command)
      calls[#calls + 1] = { command = command, database = database }
      local name = command:get_at(1)

      if name == "find" then
        return bson.document({
          { "ok", 1 },
          { "operationTime", bson.timestamp(9, 1) },
          { "cursor", bson.document({
            { "id", bson.int64(12) },
            { "ns", "db.items" },
            { "firstBatch", bson.array({}) },
          }) },
        })
      elseif name == "getMore" then
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "db.items" },
            { "nextBatch", bson.array({}) },
          }) },
        })
      end

      return bson.document({ { "ok", 1 } })
    end

    function underlying.capabilities(_)
      return {
        logical_session_timeout_minutes = 30,
        max_wire_version = 25,
      }
    end

    function underlying.close(_)
      return true
    end

    local sessions = session_module.new({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local executor = session_executor.new(underlying, sessions)
    local client = api.new_client(
      executor,
      assert(driver_options.normalize()),
      nil,
      nil,
      nil,
      sessions
    )
    local cursor = assert(client:database("db"):collection("items"):find())

    assert.is_nil(cursor:next())
    assert.are.equal(calls[1].command:get("lsid"), calls[2].command:get("lsid"))

    local explicit = assert(client:start_session())

    assert(client:database("db"):run_command(
      bson.document({ { "find", "items" } }),
      { session = explicit }
    ))
    assert(client:database("db"):run_command(
      bson.document({ { "insert", "items" } }),
      { session = explicit }
    ))
    assert.are.equal(
      bson.timestamp(9, 1),
      calls[#calls].command:get("readConcern"):get("afterClusterTime")
    )
    assert(client:close())
    assert.are.equal("endSessions", calls[#calls].command:get_at(1))
  end)

  it("dirties a session after a network failure", function()
    local sessions = session_module.new({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local underlying = {}

    function underlying.command()
      return nil, errors.new({
        category = errors.CATEGORY.NETWORK,
        message = "connection closed",
      })
    end

    function underlying.close()
      return true
    end

    local executor = session_executor.new(underlying, sessions)
    local session = assert(sessions:start())
    local failed, err = executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { session = session }
    )

    assert.is_nil(failed)
    assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
    assert.is_true(session:is_dirty())
    local dirty_lsid = assert(session:get_lsid())

    assert(session:end_session())
    assert.are_not.equal(dirty_lsid, assert(sessions:start():get_lsid()))
  end)

  it("increments txnNumber once for each logical retryable write", function()
    local sessions = session_module.new({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local commands = {}
    local underlying = {}

    function underlying.command(_, _, command)
      commands[#commands + 1] = command

      if #commands == 1 then
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          labels = { "RetryableWriteError" },
          message = "retry",
        })
      end

      return bson.document({ { "ok", 1 } })
    end

    function underlying.close()
      return true
    end

    local executor = session_executor.new(
      retry_executor.new(underlying, { enabled_writes = true }),
      sessions,
      { retryable_writes = true }
    )
    local session = assert(sessions:start())

    assert(executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { retryable_write = true, session = session }
    ))
    assert(executor:command(
      "db",
      bson.document({ { "update", "items" } }),
      { retryable_write = true, session = session }
    ))
    assert.are.equal(bson.int64(1), commands[1]:get("txnNumber"))
    assert.are.equal(bson.int64(1), commands[2]:get("txnNumber"))
    assert.are.equal(bson.int64(2), commands[3]:get("txnNumber"))
  end)

  it("decorates and commits one explicit transaction", function()
    local transaction_commands = {}
    local sessions = session_module.new({
      id_factory = identifiers(),
      timeout_minutes = 30,
      transaction_command = function(_, name)
        transaction_commands[#transaction_commands + 1] = name
        return bson.document({ { "ok", 1 } })
      end,
    })
    local session = assert(sessions:start())

    assert(session:start_transaction({
      read_concern = bson.document({ { "level", "majority" } }),
    }))
    assert.is_true(session:is_in_transaction())
    local first = assert(sessions:decorate(
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    local second = assert(sessions:decorate(
      bson.document({ { "find", "items" } }),
      { session = session }
    ))

    assert.is_true(first:get("startTransaction"))
    assert.is_false(first:get("autocommit"))
    assert.are.equal("majority", first:get("readConcern"):get("level"))
    assert.are.equal(first:get("txnNumber"), second:get("txnNumber"))
    assert.is_nil(second:get("startTransaction"))
    assert.is_nil(second:get("readConcern"))
    assert(session:commit_transaction())
    assert.same({ "commitTransaction" }, transaction_commands)
    assert.is_false(session:is_in_transaction())
    assert(session:commit_transaction())
    assert.same({ "commitTransaction", "commitTransaction" }, transaction_commands)
  end)
end)
