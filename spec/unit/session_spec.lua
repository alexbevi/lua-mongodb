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

local FIXTURE_ROOT = (os.getenv("PWD") or ".")
  .. "/planning/specifications/source/"

local function read_fixture(relative)
  local file = assert(io.open(FIXTURE_ROOT .. relative, "rb"))
  local content = file:read("*a")

  file:close()
  return assert(bson.json.decode(content))
end

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

  it("configures snapshot sessions without causal consistency", function()
    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local operation_time = bson.timestamp(4, 2)
    local ordinary = assert(sessions:start())

    assert(ordinary:advance_operation_time(operation_time))
    local ordinary_command = assert(sessions:decorate(
      bson.document({ { "find", "items" } }),
      { read_concern = bson.document({}), session = ordinary }
    ))
    assert.are.equal(
      operation_time,
      ordinary_command:get("readConcern"):get("afterClusterTime")
    )

    local snapshot = assert(sessions:start({ snapshot = true }))
    assert(snapshot:advance_operation_time(operation_time))
    local snapshot_command = assert(sessions:decorate(
      bson.document({ { "find", "items" } }),
      { read_concern = bson.document({}), session = snapshot }
    ))
    assert.is_nil(
      snapshot_command:get("readConcern"):get("afterClusterTime")
    )
    assert(sessions:start({
      snapshot = true,
      snapshot_time = bson.timestamp(9, 1),
    }))

    local validation_sessions = new_session_manager({
      id_factory = function()
        error("invalid options allocated a server session")
      end,
      timeout_minutes = 30,
    })

    assert.has_error(function()
      validation_sessions:start({ snapshot = "true" })
    end, "snapshot must be a boolean")
    assert.has_error(function()
      validation_sessions:start({
        snapshot = true,
        causal_consistency = true,
      })
    end, "snapshot sessions do not support causal_consistency=true")
    assert.has_error(function()
      validation_sessions:start({ snapshot_time = bson.timestamp(9, 1) })
    end, "snapshot_time requires snapshot=true")
    assert.has_error(function()
      validation_sessions:start({ snapshot = true, snapshot_time = 9 })
    end, "snapshot_time must be a BSON timestamp")
  end)

  it("rejects snapshot commands before using a pre-5.0 server", function()
    local commands = {}
    local underlying = {}

    function underlying.command(_, _, command)
      commands[#commands + 1] = command
      return bson.document({ { "ok", 1 } })
    end

    function underlying.close()
      return true
    end

    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local executor = session_executor.new(underlying, sessions, {
      max_wire_version = 12,
    })
    local snapshot = assert(sessions:start({ snapshot = true }))

    for _, name in ipairs({ "find", "aggregate", "distinct" }) do
      local response, err = executor:command(
        "db",
        bson.document({ { name, "items" } }),
        { session = snapshot }
      )

      assert.is_nil(response)
      assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
      assert.are.equal(
        "Snapshot reads require MongoDB 5.0 or later",
        err.message
      )
    end

    assert.are.equal(0, #commands)
    local ordinary = assert(sessions:start())

    assert(executor:command(
      "db",
      bson.document({ { "find", "items" } }),
      { session = ordinary }
    ))
    assert.are.equal(1, #commands)
  end)

  it("decorates every snapshot command with snapshot read concern", function()
    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local snapshot = assert(sessions:start({ snapshot = true }))

    for _, name in ipairs({ "find", "insert", "listCollections", "ping" }) do
      local decorated = assert(sessions:decorate(
        bson.document({ { name, "items" } }),
        { session = snapshot }
      ))
      local read_concern = assert(decorated:get("readConcern"))

      assert.are.equal("snapshot", read_concern:get("level"))
    end

    local ordinary = assert(sessions:start())
    local decorated = assert(sessions:decorate(
      bson.document({ { "find", "items" } }),
      { session = ordinary }
    ))

    assert.is_nil(decorated:get("readConcern"))
  end)

  it("captures and reuses snapshot read timestamps", function()
    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local snapshot = assert(sessions:start({ snapshot = true }))
    local first = assert(sessions:decorate(
      bson.document({ { "find", "items" } }),
      { session = snapshot }
    ))

    assert.is_nil(first:get("readConcern"):get("atClusterTime"))
    local captured = bson.timestamp(9, 1)

    assert(sessions:advance(bson.document({
      { "cursor", bson.document({ { "atClusterTime", captured } }) },
    }), snapshot))
    local second = assert(sessions:decorate(
      bson.document({ { "aggregate", "items" } }),
      { session = snapshot }
    ))

    assert.are.equal(
      captured,
      second:get("readConcern"):get("atClusterTime")
    )
    assert(sessions:advance(
      bson.document({ { "atClusterTime", bson.timestamp(12, 1) } }),
      snapshot
    ))
    local third = assert(sessions:decorate(
      bson.document({ { "distinct", "items" } }),
      { session = snapshot }
    ))

    assert.are.equal(
      captured,
      third:get("readConcern"):get("atClusterTime")
    )

    local supplied = bson.timestamp(15, 2)
    local initialized = assert(sessions:start({
      snapshot = true,
      snapshot_time = supplied,
    }))
    local initial = assert(sessions:decorate(
      bson.document({ { "find", "items" } }),
      { session = initialized }
    ))

    assert.are.equal(
      supplied,
      initial:get("readConcern"):get("atClusterTime")
    )
  end)

  it("exposes snapshot read time without allowing mutation", function()
    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local ordinary = assert(sessions:start())

    assert.is_nil(ordinary:get_snapshot_time())
    local supplied = bson.timestamp(15, 2)
    local snapshot = assert(sessions:start({
      snapshot = true,
      snapshot_time = supplied,
    }))

    assert.are.equal(supplied, snapshot:get_snapshot_time())
    assert.has_error(function()
      snapshot.snapshot_time = bson.timestamp(20, 1)
    end, "MongoDB client sessions are immutable")
    assert.are.equal(supplied, snapshot:get_snapshot_time())
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

  it("runs the exact load-balanced implicit-session reuse case", function()
    local fixture = read_fixture("load-balancers/tests/transactions.json")
    local database = fixture:get("createEntities"):get(3):get("database")
    local collection = fixture:get("createEntities"):get(4):get("collection")
    local case = fixture:get("tests"):get(1)
    local current_time = 10
    local commands = {}
    local underlying = {}

    function underlying.command(_, database_name, command)
      commands[#commands + 1] = {
        command = command,
        database = database_name,
      }
      return bson.document({ { "ok", 1 } })
    end

    function underlying.close(_)
      return true
    end

    local sessions = new_session_manager({
      clock = {
        now = function() return current_time end,
      },
      id_factory = identifiers(),
      load_balanced = true,
      timeout_minutes = 1,
    })
    local executor = session_executor.new(underlying, sessions)

    for _, operation in case:get("operations"):iter() do
      if operation:get("name") == "insertOne" then
        assert(executor:command(
          database:get("databaseName"),
          bson.document({
            { "insert", collection:get("collectionName") },
            { "documents", bson.array({
              operation:get("arguments"):get("document"),
            }) },
          })
        ))
        current_time = current_time + 1000000
      else
        assert.are.equal("assertSameLsidOnLastTwoCommands", operation:get("name"))
      end
    end

    assert.are.equal(2, #commands)
    assert.are.equal(database:get("databaseName"), commands[1].database)
    assert.are.equal(
      assert(bson.json.encode(commands[1].command:get("lsid"), {
        mode = "canonical",
      })),
      assert(bson.json.encode(commands[2].command:get("lsid"), {
        mode = "canonical",
      }))
    )
    assert(executor:close())
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

  it("pins later transaction commands to the first selected mongos", function()
    local selected_addresses = {}
    local underlying = {
      close = function() return true end,
      command = function(_, _, _, options)
        selected_addresses[#selected_addresses + 1] =
          options.server_address or false
        assert.is_function(options.on_server_selected)
        options.on_server_selected("router-a:27017", "Mongos")
        return bson.document({ { "ok", 1 } })
      end,
    }
    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local executor = session_executor.new(underlying, sessions)
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(executor:command(
      "db",
      bson.document({ { "find", "items" } }),
      { session = session }
    ))
    assert(executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert.same({ false, "router-a:27017" }, selected_addresses)
  end)

  it("retains one load-balanced transaction pin through repeated commits", function()
    local command_pins = {}
    local executor
    local pin_count = 0
    local release_count = 0
    local transaction_pin
    local underlying = {
      close = function() return true end,
      command = function(_, _, _, options)
        if options.pin_connection then
          pin_count = pin_count + 1
          transaction_pin = {
            release = function()
              release_count = release_count + 1
              return true
            end,
          }
          options.on_connection_pinned(transaction_pin)
        end

        command_pins[#command_pins + 1] = options.pinned_connection
          or transaction_pin
        return bson.document({ { "ok", 1 } })
      end,
    }
    local sessions = new_session_manager({
      id_factory = identifiers(),
      load_balanced = true,
      transaction_command = function(session, name)
        return executor:command(
          "admin",
          bson.document({ { name, 1 } }),
          { session = session, transaction_control = true }
        )
      end,
    })

    executor = session_executor.new(underlying, sessions)
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert.is_not_nil(transaction_pin)
    assert(executor:command(
      "db",
      bson.document({ { "find", "items" } }),
      { session = session }
    ))

    for _ = 1, 4 do
      assert(session:commit_transaction())
    end

    assert.is_true(session:is_pinned())
    assert.are.equal(1, pin_count)
    assert.are.equal(0, release_count)
    assert.are.equal(6, #command_pins)

    for _, pin in ipairs(command_pins) do
      assert.are.equal(transaction_pin, pin)
    end
  end)

  it("retries a load-balanced commit on a fresh connection pin", function()
    local command_count = 0
    local pins = {}
    local release_counts = {}
    local executor
    local underlying = {
      close = function() return true end,
      command = function(_, _, _, options)
        command_count = command_count + 1

        if options.pin_connection then
          local index = #pins + 1
          local pin = {
            release = function()
              release_counts[index] = release_counts[index] + 1
              return true
            end,
          }

          pins[index] = pin
          release_counts[index] = 0
          options.on_connection_pinned(pin)
        end

        if command_count == 2 then
          return nil, errors.new({
            category = errors.CATEGORY.NETWORK,
            message = "commit connection closed",
          })
        end

        return bson.document({ { "ok", 1 } })
      end,
    }
    local sessions = new_session_manager({
      id_factory = identifiers(),
      load_balanced = true,
      transaction_command = function(session, name)
        return executor:command(
          "admin",
          bson.document({ { name, 1 } }),
          { session = session, transaction_control = true }
        )
      end,
    })

    executor = session_executor.new(underlying, sessions)
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert(session:commit_transaction())

    assert.are.equal(3, command_count)
    assert.are.equal(2, #pins)
    assert.are_not.equal(pins[1], pins[2])
    assert.are.equal(1, release_counts[1])
    assert.are.equal(0, release_counts[2])
    assert.are.equal(pins[2], session:get_pinned_connection())
  end)

  it("releases a load-balanced pin after a transient commit error", function()
    local release_count = 0
    local transient_error = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 24,
      labels = { "TransientTransactionError" },
      message = "transaction lock request timed out",
    })
    local sessions = new_session_manager({
      id_factory = identifiers(),
      load_balanced = true,
      transaction_command = function()
        return nil, transient_error
      end,
    })
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(sessions:decorate(
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert(session:pin_connection({
      release = function()
        release_count = release_count + 1
        return true
      end,
    }))
    local response, err = session:commit_transaction()

    assert.is_nil(response)
    assert.are.equal(transient_error, err)
    assert.is_false(session:is_pinned())
    assert.are.equal(1, release_count)
  end)

  it("repins a new load-balanced transaction on a fresh connection", function()
    local commands = {}
    local pins = {}
    local release_counts = {}
    local executor
    local underlying = {
      close = function() return true end,
      command = function(_, _, command, options)
        commands[#commands + 1] = command

        if options.pin_connection then
          local index = #pins + 1
          local pin = {
            release = function()
              release_counts[index] = release_counts[index] + 1
              return true
            end,
          }

          pins[index] = pin
          release_counts[index] = 0
          options.on_connection_pinned(pin)
        end

        return bson.document({ { "ok", 1 } })
      end,
    }
    local sessions = new_session_manager({
      id_factory = identifiers(),
      load_balanced = true,
      transaction_command = function(session, name)
        return executor:command(
          "admin",
          bson.document({ { name, 1 } }),
          { session = session, transaction_control = true }
        )
      end,
    })

    executor = session_executor.new(underlying, sessions)
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert(session:commit_transaction())
    assert.are.equal(0, release_counts[1])

    assert(session:start_transaction())
    assert.are.equal(1, release_counts[1])
    assert(executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))

    assert.are.equal(2, #pins)
    assert.are_not.equal(pins[1], pins[2])
    assert.are.equal(commands[1]:get("lsid"), commands[3]:get("lsid"))
    assert.are.equal(bson.int64(1), commands[1]:get("txnNumber"))
    assert.are.equal(bson.int64(2), commands[3]:get("txnNumber"))
    assert(session:abort_transaction())
    assert.are.equal(1, release_counts[2])
  end)

  it("unpins before an ordinary session operation", function()
    local commands = {}
    local release_count = 0
    local executor
    local underlying = {
      close = function() return true end,
      command = function(_, _, command, options)
        commands[#commands + 1] = command

        if options.pin_connection then
          options.on_connection_pinned({
            release = function()
              release_count = release_count + 1
              return true
            end,
          })
        end

        return bson.document({ { "ok", 1 } })
      end,
    }
    local sessions = new_session_manager({
      id_factory = identifiers(),
      load_balanced = true,
      transaction_command = function(session, name)
        return executor:command(
          "admin",
          bson.document({ { name, 1 } }),
          { session = session, transaction_control = true }
        )
      end,
    })

    executor = session_executor.new(underlying, sessions)
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert(session:commit_transaction())
    assert.is_true(session:is_pinned())
    assert(executor:command(
      "db",
      bson.document({ { "ping", 1 } }),
      { session = session }
    ))

    assert.is_false(session:is_pinned())
    assert.are.equal(1, release_count)
    assert.are.equal(commands[1]:get("lsid"), commands[3]:get("lsid"))
    assert.is_nil(commands[3]:get("txnNumber"))
  end)

  it("releases a committed load-balanced pin when the session ends", function()
    local release_count = 0
    local sessions = new_session_manager({
      id_factory = identifiers(),
      load_balanced = true,
      transaction_command = function()
        return bson.document({ { "ok", 1 } })
      end,
    })
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(sessions:decorate(
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert(session:pin_connection({
      release = function()
        release_count = release_count + 1
        return true
      end,
    }))
    assert(session:commit_transaction())
    assert.is_true(session:is_pinned())

    assert(session:end_session())
    assert.is_false(session:is_pinned())
    assert.are.equal(1, release_count)
    assert(session:end_session())
    assert.are.equal(1, release_count)
  end)

  it("releases a load-balanced pin after a successful abort", function()
    local release_count = 0
    local sessions = new_session_manager({
      id_factory = identifiers(),
      load_balanced = true,
      transaction_command = function()
        return bson.document({ { "ok", 1 } })
      end,
    })
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(sessions:decorate(
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert(session:pin_connection({
      release = function()
        release_count = release_count + 1
        return true
      end,
    }))
    assert(session:abort_transaction())

    assert.is_false(session:is_pinned())
    assert.are.equal(1, release_count)
  end)

  it("releases a load-balanced pin after a transient abort error", function()
    local release_count = 0
    local sessions = new_session_manager({
      id_factory = identifiers(),
      load_balanced = true,
      transaction_command = function()
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          code = 24,
          labels = { "TransientTransactionError" },
          message = "transaction lock request timed out",
        })
      end,
    })
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(sessions:decorate(
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert(session:pin_connection({
      release = function()
        release_count = release_count + 1
        return true
      end,
    }))
    assert(session:abort_transaction())

    assert.is_false(session:is_pinned())
    assert.are.equal(1, release_count)
  end)

  it("releases a load-balanced pin after an ordinary abort error", function()
    local release_count = 0
    local sessions = new_session_manager({
      id_factory = identifiers(),
      load_balanced = true,
      transaction_command = function()
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          code = 123,
          message = "abort rejected",
        })
      end,
    })
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(sessions:decorate(
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert(session:pin_connection({
      release = function()
        release_count = release_count + 1
        return true
      end,
    }))
    assert(session:abort_transaction())
    assert.is_false(session:is_pinned())
    assert.are.equal(1, release_count)
  end)

  it("retains load-balanced pins after ordinary CRUD and commit errors", function()
    local command_count = 0
    local release_count = 0
    local ordinary_error = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 123,
      message = "operation rejected",
    })
    local underlying = {
      close = function() return true end,
      command = function(_, _, _, options)
        command_count = command_count + 1

        if command_count == 1 then
          options.on_connection_pinned({
            release = function()
              release_count = release_count + 1
              return true
            end,
          })
          return bson.document({ { "ok", 1 } })
        end

        assert.is_not_nil(options.pinned_connection)
        return nil, ordinary_error
      end,
    }
    local sessions = new_session_manager({
      id_factory = identifiers(),
      load_balanced = true,
      transaction_command = function()
        return nil, ordinary_error
      end,
    })
    local executor = session_executor.new(underlying, sessions)
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    local response, err = executor:command(
      "db",
      bson.document({ { "update", "items" } }),
      { session = session }
    )

    assert.is_nil(response)
    assert.are.equal(ordinary_error, err)
    assert.is_true(session:is_pinned())
    response, err = session:commit_transaction()
    assert.is_nil(response)
    assert.are.equal(ordinary_error, err)
    assert.is_true(session:is_pinned())
    assert.are.equal(0, release_count)
    assert(session:unpin_connection())
    assert.are.equal(1, release_count)
  end)

  it("shares a load-balanced transaction pin with its cursor", function()
    local release_count = 0
    local pin = {
      release = function()
        release_count = release_count + 1
        return true
      end,
    }
    local underlying = {
      close = function() return true end,
      command = function(_, _, command, options)
        local name = command:keys()[1]

        if name == "insert" then
          assert.is_true(options.pin_connection)
          assert.is_function(options.on_connection_pinned)
          options.on_connection_pinned(pin)
          return bson.document({ { "ok", 1 }, { "n", 1 } })
        elseif name == "endSessions" then
          assert.is_nil(options.pinned_connection)
          return bson.document({ { "ok", 1 } })
        end

        assert.are.equal(pin, options.pinned_connection)
        assert.is_nil(options.pin_connection)
        assert.is_nil(options.on_connection_pinned)

        if name == "find" then
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(41) },
              { "ns", "db.items" },
              { "firstBatch", bson.array({}) },
            }) },
          })
        end

        assert.is_true(name == "killCursors" or name == "abortTransaction")
        return bson.document({ { "ok", 1 } })
      end,
    }
    local executor
    local sessions = new_session_manager({
      id_factory = identifiers(),
      load_balanced = true,
      timeout_minutes = 30,
      transaction_command = function(session, name)
        return executor:command(
          "admin",
          bson.document({ { name, 1 } }),
          { session = session, transaction_control = true }
        )
      end,
    })

    executor = session_executor.new(underlying, sessions)
    local client = api.new_client(
      executor,
      assert(driver_options.normalize()),
      nil,
      nil,
      nil,
      sessions
    )
    local collection = client:database("db"):collection("items")
    local session = assert(client:start_session())

    assert(session:start_transaction())
    assert(collection:insert_one(
      bson.document({ { "_id", 1 } }),
      { session = session }
    ))
    local cursor = assert(collection:find(nil, {
      batch_size = 2,
      session = session,
    }))

    assert.is_true(session:is_pinned())
    assert.are.equal(0, release_count)
    assert(cursor:close())
    assert.is_true(session:is_pinned())
    assert.are.equal(0, release_count)
    assert(session:abort_transaction())
    assert.is_false(session:is_pinned())
    assert.are.equal(1, release_count)
    assert(session:end_session())
    assert(client:close())
  end)

  it("releases a load-balanced pin after a transient CRUD error", function()
    local command_count = 0
    local release_count = 0
    local transient_error = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 91,
      labels = { "TransientTransactionError" },
      message = "transaction interrupted",
    })
    local underlying = {
      close = function() return true end,
      command = function(_, _, _, options)
        command_count = command_count + 1

        if command_count == 1 then
          options.on_connection_pinned({
            release = function()
              release_count = release_count + 1
              return true
            end,
          })
          return bson.document({ { "ok", 1 } })
        end

        return nil, transient_error
      end,
    }
    local sessions = new_session_manager({
      id_factory = identifiers(),
      load_balanced = true,
    })
    local executor = session_executor.new(underlying, sessions)
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    local response, err = executor:command(
      "db",
      bson.document({ { "update", "items" } }),
      { session = session }
    )

    assert.is_nil(response)
    assert.are.equal(transient_error, err)
    assert.is_false(session:is_pinned())
    assert.are.equal(1, release_count)
  end)

  it("unpins only transient transaction application errors", function()
    local pending_error
    local underlying = {
      close = function() return true end,
      command = function(_, _, _, options)
        options.on_server_selected("router-a:27017", "Mongos")
        return nil, pending_error
      end,
    }
    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
    })
    local executor = session_executor.new(underlying, sessions)
    local transient = assert(sessions:start())

    pending_error = errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "connection closed",
    })
    assert(transient:start_transaction())
    local response, err = executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { session = transient }
    )

    assert.is_nil(response)
    assert.is_true(err:has_label("TransientTransactionError"))
    assert.is_false(transient:is_pinned())

    local non_transient = assert(sessions:start())

    pending_error = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 11601,
      message = "interrupted",
    })
    assert(non_transient:start_transaction())
    response, err = executor:command(
      "db",
      bson.document({ { "insert", "items" } }),
      { session = non_transient }
    )

    assert.is_nil(response)
    assert.is_false(err:has_label("TransientTransactionError"))
    assert.is_true(non_transient:is_pinned())
  end)

  it("unpins a transaction after a successful abort", function()
    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
      transaction_command = function()
        return bson.document({ { "ok", 1 } })
      end,
    })
    local session = assert(sessions:start())

    assert(session:start_transaction())
    assert(sessions:decorate(
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert(session:pin_server("router-a:27017", "Mongos"))
    assert.is_true(session:is_pinned())
    assert(session:abort_transaction())
    assert.is_false(session:is_pinned())
  end)

  it("forwards the latest recovery token to transaction control", function()
    local transaction_command
    local sessions

    sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
      transaction_command = function(session, name)
        transaction_command = assert(sessions:decorate(
          bson.document({ { name, 1 } }),
          { session = session, transaction_control = true }
        ))
        return bson.document({ { "ok", 1 } })
      end,
    })
    local session = assert(sessions:start())
    local first_token = bson.document({ { "shard", "a" } })
    local latest_token = bson.document({ { "shard", "b" } })
    local failed_token = bson.document({ { "shard", "ignored" } })

    assert(session:start_transaction())
    assert(sessions:decorate(
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert(sessions:advance(bson.document({
      { "ok", 1 },
      { "recoveryToken", first_token },
    }), session))
    assert(sessions:advance(bson.document({
      { "ok", 1 },
      { "recoveryToken", latest_token },
    }), session))
    assert(sessions:advance(bson.document({
      { "ok", 0 },
      { "recoveryToken", failed_token },
    }), session))
    assert(session:commit_transaction())
    local forwarded_token = transaction_command:get("recoveryToken")

    assert.is_not_nil(forwarded_token)
    assert.are.equal(latest_token, forwarded_token)

    assert(session:start_transaction())
    assert(sessions:decorate(
      bson.document({ { "insert", "items" } }),
      { session = session }
    ))
    assert(session:abort_transaction())
    assert.is_nil(transaction_command:get("recoveryToken"))
  end)

  it("rejects transactions on snapshot sessions", function()
    local transaction_commands = 0
    local sessions = new_session_manager({
      id_factory = identifiers(),
      timeout_minutes = 30,
      transaction_command = function()
        transaction_commands = transaction_commands + 1
        return bson.document({ { "ok", 1 } })
      end,
    })
    local session = assert(sessions:start({ snapshot = true }))
    local started, err = session:start_transaction()

    assert.is_nil(started)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(
      "Transactions are not supported in snapshot sessions",
      err.message
    )
    assert.are.equal("none", session:get_transaction_state())
    assert.are.equal(0, transaction_commands)
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
