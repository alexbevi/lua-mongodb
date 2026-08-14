local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local api = require("mongodb.api")
local command_executor = require("mongodb.command.executor")
local driver_options = require("mongodb.config.options")
local op_msg = require("mongodb.wire.op_msg")
local retry_executor = require("mongodb.retry_executor")
local session_module = require("mongodb.session")
local session_executor = require("mongodb.session_executor")
local fake_runtime = require("mongodb.runtime.fake")
local socket_timeout_executor = require("mongodb.socket_timeout_executor")
local standalone_executor = require("mongodb.standalone_executor")

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

local function new_session_manager(options)
  if options.clock == nil then
    local runtime = fake_runtime.new()

    options.clock = runtime.clock
    options.runtime = options.runtime or runtime
  end

  return session_module.new(options)
end

describe("client sessions", function()
  it("measures through executor decorators without consuming transaction state", function()
    local pending_response
    local requests = {}
    local connection = {}

    function connection.write_all(_, bytes)
      local request = assert(op_msg.decode(bytes, { direction = "request" }))

      requests[#requests + 1] = request
      local response = #requests == 1 and bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }) or bson.document({ { "ok", 1 } })
      pending_response = assert(op_msg.encode({
        body = response,
        direction = "response",
        request_id = 700 + request.request_id,
        response_to = request.request_id,
      }))
      return true
    end

    function connection.read_frame()
      return pending_response
    end

    function connection.close()
      return true
    end

    local commands = command_executor.new(connection)

    assert(commands:hello())
    local reconnecting = standalone_executor.new(
      commands,
      function()
        return commands
      end,
      commands:capabilities()
    )
    local runtime = fake_runtime.new()
    local timed = socket_timeout_executor.new(reconnecting, runtime, 100)
    local retrying = retry_executor.new(timed, { enabled_writes = true })
    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local executor = session_executor.new(retrying, sessions, {
      retryable_writes = true,
    })
    local session = assert(sessions:start())
    local command = bson.document({ { "insert", "items" } })
    local sequences = {
      {
        documents = { bson.document({ { "value", 1 } }) },
        identifier = "documents",
      },
    }

    assert(session:start_transaction())
    local measured = assert(executor:measure("db", command, {
      sequences = sequences,
      session = session,
    }))

    assert.is_true(measured.message_size > 0)
    assert.are.equal(1, #requests)

    local oversized, err = executor:measure("db", command, {
      max_sequence_document_size = 5,
      sequences = sequences,
      session = session,
    })

    assert.is_nil(oversized)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
    assert.are.equal(1, #requests)
    assert(executor:command("db", command, {
      sequences = sequences,
      session = session,
    }))
    assert.is_true(requests[2].body:get("startTransaction"))
    assert.is_true(executor:close())
  end)

  it("inherits and overrides the client operation timeout", function()
    local runtime = fake_runtime.new({ now = 3 })
    local deadlines = {}
    local sessions = new_session_manager({
      clock = runtime.clock,
      default_timeout_ms = 100,
      id_factory = identifiers(),
      runtime = runtime,
      timeout_minutes = 30,
    })
    local underlying = {
      close = function() return true end,
      command = function(_, _, _, options)
        deadlines[#deadlines + 1] = options.deadline
        return bson.document({ { "ok", 1 } })
      end,
    }
    local executor = session_executor.new(underlying, sessions)
    local inherited = assert(sessions:start())
    local overridden = assert(sessions:start({ timeout_ms = 20 }))

    assert(executor:command(
      "db",
      bson.document({ { "ping", 1 } }),
      { session = inherited }
    ))
    assert(executor:command(
      "db",
      bson.document({ { "ping", 1 } }),
      { session = overridden }
    ))
    assert.near(3.1, deadlines[1], 0.000001)
    assert.near(3.02, deadlines[2], 0.000001)
  end)

  it("decorates causal commands and rejects an ended session", function()
    local identifier = bson.document({
      { "id", bson.binary(string.rep("s", 16), bson.BINARY_SUBTYPE.UUID) },
    })
    local sessions = new_session_manager({
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

    assert.are.same({ "find", "lsid", "readConcern" }, command:keys())
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
    local sessions = new_session_manager({
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

  it("expires server sessions through the injected monotonic clock", function()
    local current_time = 10
    local sessions = new_session_manager({
      clock = {
        now = function()
          return current_time
        end,
        wall_time = function()
          error("session bookkeeping must not read wall time")
        end,
      },
      id_factory = identifiers(),
      timeout_minutes = 3,
    })
    local first = assert(sessions:start())
    local first_lsid = assert(first:get_lsid())

    assert(first:end_session())
    current_time = current_time + 119
    local reused = assert(sessions:start())

    assert.are.equal(first_lsid, assert(reused:get_lsid()))
    assert(reused:end_session())
    current_time = current_time + 120
    local replacement = assert(sessions:start())

    assert.are_not.equal(first_lsid, assert(replacement:get_lsid()))
  end)

  it("rejects session bookkeeping without a runtime clock", function()
    assert.has_error(function()
      session_module.new({ id_factory = identifiers() })
    end, "session manager requires a runtime clock adapter")
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

    local sessions = new_session_manager({
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
    local sessions = new_session_manager({
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
    local sessions = new_session_manager({
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
    assert.are.same({ "insert", "lsid", "txnNumber" }, commands[1]:keys())
    assert.are.same({ "update", "lsid", "txnNumber" }, commands[3]:keys())
  end)

  it("decorates and commits one explicit transaction", function()
    local transaction_commands = {}
    local sessions = new_session_manager({
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

    assert.are.same({
      "insert",
      "lsid",
      "txnNumber",
      "autocommit",
      "startTransaction",
      "readConcern",
    }, first:keys())
    assert.are.same({
      "find",
      "lsid",
      "txnNumber",
      "autocommit",
    }, second:keys())
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

  it("retries abort after a retryable authentication handshake failure", function()
    local abort_attempts = 0
    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
      transaction_command = function(_, name)
        assert.are.equal("abortTransaction", name)
        abort_attempts = abort_attempts + 1

        if abort_attempts == 1 then
          return nil, errors.new({
            category = errors.CATEGORY.AUTHENTICATION,
            message = "SCRAM authentication command failed",
            retryable = true,
          })
        end

        return bson.document({ { "ok", 1 } })
      end,
    })
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(sessions:decorate(
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert(session:abort_transaction())
    assert.are.equal(2, abort_attempts)
    assert.are.equal("aborted", session:get_transaction_state())

    local aborted, err = session:abort_transaction()

    assert.is_nil(aborted)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(2, abort_attempts)
  end)

  it("retries commit after a retryable authentication handshake failure", function()
    local commit_attempts = {}
    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
      transaction_command = function(_, name, _, retrying_commit)
        assert.are.equal("commitTransaction", name)
        commit_attempts[#commit_attempts + 1] = retrying_commit

        if #commit_attempts == 1 then
          return nil, errors.new({
            category = errors.CATEGORY.AUTHENTICATION,
            message = "SCRAM authentication command failed",
            retryable = true,
          })
        end

        return bson.document({ { "ok", 1 } })
      end,
    })
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(sessions:decorate(
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))

    assert(session:commit_transaction())
    assert.same({ false, true }, commit_attempts)
    assert.are.equal("committed", session:get_transaction_state())
  end)

  it("does not mask a transaction read preference with an operation preference", function()
    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local session = assert(sessions:start())

    assert(session:start_transaction({
      read_preference = { mode = "secondary" },
    }))
    local command, err = sessions:decorate(
      bson.document({ { "find", "items" } }),
      {
        read_preference = { mode = "primary" },
        session = session,
      }
    )

    assert.is_nil(command)
    assert.matches("read preference in a transaction must be primary", err.message)
  end)

  it("returns the callback value after a convenient transaction commits", function()
    local transaction_commands = {}
    local sessions = new_session_manager({
      clock = {
        now = function() return 0 end,
        sleep = function() return true end,
        wall_time = function() return 0 end,
      },
      id_factory = identifiers(),
      timeout_minutes = 30,
      transaction_command = function(_, name)
        transaction_commands[#transaction_commands + 1] = name
        return bson.document({ { "ok", 1 } })
      end,
    })
    local session = assert(sessions:start())
    local result = assert(session:with_transaction(function(active_session)
      assert.are.equal(session, active_session)
      assert(sessions:decorate(
        bson.document({ { "insert", "items" } }),
        { session = active_session }
      ))
      return "callback result"
    end))

    assert.are.equal("callback result", result)
    assert.same({ "commitTransaction" }, transaction_commands)
  end)

  it("retries a transient callback after aborting and backing off", function()
    local current_time = 0
    local sleeps = {}
    local transaction_commands = {}
    local sessions = new_session_manager({
      clock = {
        now = function() return current_time end,
        sleep = function(_, duration)
          sleeps[#sleeps + 1] = duration
          current_time = current_time + duration
          return true
        end,
        wall_time = function() return 0 end,
      },
      id_factory = identifiers(),
      timeout_minutes = 30,
      transaction_command = function(_, name)
        transaction_commands[#transaction_commands + 1] = name
        return bson.document({ { "ok", 1 } })
      end,
      transaction_jitter = function() return 1 end,
    })
    local session = assert(sessions:start())
    local callback_count = 0
    local result = assert(session:with_transaction(function(active_session)
      callback_count = callback_count + 1
      assert(sessions:decorate(
        bson.document({ { "insert", "items" } }),
        { session = active_session }
      ))

      if callback_count == 1 then
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          labels = { "TransientTransactionError" },
          message = "retry transaction",
        })
      end

      return "retried result"
    end))

    assert.are.equal("retried result", result)
    assert.are.equal(2, callback_count)
    assert.same({ 0.005 }, sleeps)
    assert.same({ "abortTransaction", "commitTransaction" }, transaction_commands)
  end)

  it("retries an unknown commit result without rerunning the callback", function()
    local commit_count = 0
    local sessions = new_session_manager({
      clock = {
        now = function() return 0 end,
        sleep = function() return true end,
        wall_time = function() return 0 end,
      },
      id_factory = identifiers(),
      timeout_minutes = 30,
      transaction_command = function()
        commit_count = commit_count + 1

        if commit_count == 1 then
          return nil, errors.new({
            category = errors.CATEGORY.SERVER,
            labels = { "UnknownTransactionCommitResult" },
            message = "unknown commit result",
          })
        end

        return bson.document({ { "ok", 1 } })
      end,
    })
    local session = assert(sessions:start())
    local callback_count = 0

    assert(session:with_transaction(function(active_session)
      callback_count = callback_count + 1
      assert(sessions:decorate(
        bson.document({ { "insert", "items" } }),
        { session = active_session }
      ))
      return true
    end))
    assert.are.equal(1, callback_count)
    assert.are.equal(2, commit_count)
  end)

  it("aborts and returns a callback error without retrying", function()
    local transaction_commands = {}
    local callback_err = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "callback failed",
    })
    local sessions = new_session_manager({
      clock = {
        now = function() return 0 end,
        sleep = function() return true end,
        wall_time = function() return 0 end,
      },
      id_factory = identifiers(),
      timeout_minutes = 30,
      transaction_command = function(_, name)
        transaction_commands[#transaction_commands + 1] = name
        return bson.document({ { "ok", 1 } })
      end,
    })
    local session = assert(sessions:start())
    local result, err = session:with_transaction(function(active_session)
      assert(sessions:decorate(
        bson.document({ { "insert", "items" } }),
        { session = active_session }
      ))
      return nil, callback_err
    end)

    assert.is_nil(result)
    assert.are.equal(callback_err, err)
    assert.same({ "abortTransaction" }, transaction_commands)
  end)

  it("preserves the retry cause and labels when its time budget expires", function()
    local callback_err = errors.new({
      category = errors.CATEGORY.SERVER,
      labels = { "TransientTransactionError" },
      message = "retry transaction",
    })
    local sessions = new_session_manager({
      clock = {
        now = function() return 0 end,
        sleep = function() return true end,
        wall_time = function() return 0 end,
      },
      id_factory = identifiers(),
      timeout_minutes = 30,
      transaction_command = function()
        return bson.document({ { "ok", 1 } })
      end,
      transaction_jitter = function() return 1 end,
      transaction_retry_timeout_seconds = 0.004,
    })
    local session = assert(sessions:start())
    local result, err = session:with_transaction(function(active_session)
      assert(sessions:decorate(
        bson.document({ { "insert", "items" } }),
        { session = active_session }
      ))
      return nil, callback_err
    end)

    assert.is_nil(result)
    assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))
    assert.are.equal(callback_err, err.cause)
    assert.is_true(err:has_label("TransientTransactionError"))
  end)
end)
