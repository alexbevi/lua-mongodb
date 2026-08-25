local bson = require("mongodb.bson")
local copas = require("copas")
local errors = require("mongodb.error")
local mongodb = require("mongodb")
local op_msg = require("mongodb.wire.op_msg")
local socket = require("socket")

local FIXTURE = (os.getenv("PWD") or ".")
  .. "/planning/specifications/source/load-balancers/tests/"
  .. "non-lb-connection-establishment.json"

local function receive_frame(peer)
  local header = assert(peer:receive(4))
  local size = string.unpack("<i4", header)

  return assert(op_msg.decode(header .. assert(peer:receive(size - 4)), {
    direction = "request",
  }))
end

local function send_response(peer, request, body)
  assert(peer:send(assert(op_msg.encode({
    body = body,
    direction = "response",
    request_id = 900 + request.request_id,
    response_to = request.request_id,
  }))))
end

local function run_endpoint(load_balanced, service_id, callback, handle_command)
  local server = assert(socket.bind("127.0.0.1", 0))
  local _, port = assert(server:getsockname())
  local outcome
  local server_error

  port = assert(math.tointeger(port))
  copas.addserver(server, function(peer)
    local ok, err = pcall(function()
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      if load_balanced then
        assert.are.equal("hello", handshake.body:keys()[1])
        assert.is_true(handshake.body:get("loadBalanced"))
      else
        assert.are.equal("ismaster", handshake.body:keys()[1])
        assert.is_nil(handshake.body:get("loadBalanced"))
      end

      local response = {
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }

      if service_id then
        response[#response + 1] = { "serviceId", service_id }
      end

      send_response(peer, handshake, bson.document(response))

      if load_balanced and service_id == nil then
        local trailing, close_err = peer:receive(1)

        assert.is_nil(trailing)
        assert.are.equal("closed", close_err)
      else
        while true do
          local received, request = pcall(receive_frame, peer)

          if not received then
            break
          end

          local command_name = request.body:keys()[1]

          local command_response

          if handle_command then
            command_response = handle_command(peer, request)
          else
            assert.is_true(command_name == "ping" or command_name == "endSessions")
            command_response = bson.document({ { "ok", 1 } })
          end

          if command_response then
            send_response(peer, request, command_response)
          else
            break
          end
        end
      end
    end)

    if not ok then
      server_error = err
    end

    pcall(peer.close, peer)
  end)

  copas.loop(function()
    outcome = table.pack(pcall(callback, port))
    copas.removeserver(server)
  end)

  if server_error then
    error(server_error, 0)
  elseif not outcome[1] then
    error(outcome[2], 0)
  end
end

local function load_fixture()
  local file = assert(io.open(FIXTURE, "rb"))
  local fixture = assert(bson.json.decode(file:read("*a")))

  file:close()
  return fixture
end

local function fixture_option(fixture, entity_id)
  for _, entity in fixture:get("createEntities"):iter() do
    local client = entity:get("client")

    if client and client:get("id") == entity_id then
      return client:get("uriOptions"):get("loadBalanced")
    end
  end
end

describe("load-balanced connection establishment", function()
  it("handshakes and runs a command through the pooled connection", function()
    local service_id = assert(bson.object_id("000000000000000000000001"))

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local reply = assert(client:database():run_command("ping"))

      assert.are.equal(1, reply:get("ok"):to_number())
      assert(client:close())
    end)
  end)

  it("keeps find and getMore on one checked-out connection", function()
    local service_id = assert(bson.object_id("000000000000000000000001"))
    local find_peer
    local ping_peer

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local collection = client:database():collection("users")
      local cursor = assert(collection:find(nil, { batch_size = 1 }))

      assert.are.equal(1, assert(cursor:next()):get("n"):to_number())
      assert(client:database():run_command("ping"))
      assert.are.equal(2, assert(cursor:next()):get("n"):to_number())
      assert.is_true(cursor:is_closed())
      assert(client:close())
    end, function(peer, request)
      local name = request.body:keys()[1]

      if name == "find" then
        find_peer = peer
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(41) },
            { "ns", "app.users" },
            { "firstBatch", bson.array({
              bson.document({ { "n", 1 } }),
            }) },
          }) },
        })
      elseif name == "ping" then
        ping_peer = peer
        assert.are_not.equal(find_peer, ping_peer)
        return bson.document({ { "ok", 1 } })
      elseif name == "endSessions" then
        return bson.document({ { "ok", 1 } })
      end

      assert.are.equal("getMore", name)
      assert.are.equal(find_peer, peer)
      return bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.users" },
          { "nextBatch", bson.array({
            bson.document({ { "n", 2 } }),
          }) },
        }) },
      })
    end)

    assert.is_not_nil(find_peer)
    assert.is_not_nil(ping_peer)
  end)

  it("discards a pinned connection after getMore network failure", function()
    local service_id = assert(bson.object_id("000000000000000000000001"))
    local commands = {}
    local find_peer
    local get_more_peer

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local collection = client:database():collection("users")
      local cursor = assert(collection:find(nil, { batch_size = 1 }))

      assert.are.equal(1, assert(cursor:next()):get("n"):to_number())
      local document, err = cursor:next()

      assert.is_nil(document)
      assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
      assert(client:database():run_command("ping"))
      assert.is_true(cursor:close())
      assert.is_false(cursor:close())
      assert(client:close())
    end, function(peer, request)
      local name = request.body:keys()[1]

      commands[#commands + 1] = name

      if name == "find" then
        find_peer = peer
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(41) },
            { "ns", "app.users" },
            { "firstBatch", bson.array({
              bson.document({ { "n", 1 } }),
            }) },
          }) },
        })
      elseif name == "getMore" then
        get_more_peer = peer
        peer:close()
        return nil
      end

      return bson.document({ { "ok", 1 } })
    end)

    assert.are.equal(find_peer, get_more_peer)
    assert.same({ "find", "getMore", "ping", "endSessions" }, commands)
  end)

  it("releases a pinned connection after killCursors network failure", function()
    local service_id = assert(bson.object_id("000000000000000000000001"))
    local commands = {}
    local find_peer
    local kill_peer

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local collection = client:database():collection("users")
      local cursor = assert(collection:find(nil, { batch_size = 1 }))

      assert.are.equal(1, assert(cursor:next()):get("n"):to_number())
      assert.is_true(cursor:close())
      assert.is_false(cursor:close())
      assert(client:database():run_command("ping"))
      assert(client:close())
    end, function(peer, request)
      local name = request.body:keys()[1]

      commands[#commands + 1] = name

      if name == "find" then
        find_peer = peer
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(41) },
            { "ns", "app.users" },
            { "firstBatch", bson.array({
              bson.document({ { "n", 1 } }),
            }) },
          }) },
        })
      elseif name == "killCursors" then
        kill_peer = peer
        peer:close()
        return nil
      end

      return bson.document({ { "ok", 1 } })
    end)

    assert.are.equal(find_peer, kill_peer)
    assert.same({ "find", "killCursors", "ping", "endSessions" }, commands)
  end)

  it("retains a pinned connection after getMore server failure", function()
    local service_id = assert(bson.object_id("000000000000000000000001"))
    local commands = {}
    local find_peer

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local collection = client:database():collection("users")
      local cursor = assert(collection:find(nil, { batch_size = 1 }))

      assert.are.equal(1, assert(cursor:next()):get("n"):to_number())
      local document, err = cursor:next()

      assert.is_nil(document)
      assert.is_true(errors.is(err, errors.CATEGORY.SERVER))
      assert.is_false(cursor:is_closed())
      assert.is_true(cursor:close())
      assert.is_false(cursor:close())
      assert(client:database():run_command("ping"))
      assert(client:close())
    end, function(peer, request)
      local name = request.body:keys()[1]

      commands[#commands + 1] = name

      if name == "find" then
        find_peer = peer
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(41) },
            { "ns", "app.users" },
            { "firstBatch", bson.array({
              bson.document({ { "n", 1 } }),
            }) },
          }) },
        })
      end

      assert.are.equal(find_peer, peer)

      if name == "getMore" then
        return bson.document({
          { "ok", 0 },
          { "code", 123 },
          { "errmsg", "getMore failed" },
        })
      end

      return bson.document({ { "ok", 1 } })
    end)

    assert.same(
      { "find", "getMore", "killCursors", "ping", "endSessions" },
      commands
    )
  end)

  it("pins every supported command cursor through continuation or close", function()
    local service_id = assert(bson.object_id("000000000000000000000001"))
    local cursor_connections = {}
    local next_cursor_id = 100
    local active_connection

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local database = client:database()
      local collection = database:collection("events")
      local function drain(cursor)
        assert(cursor:next())
        assert(database:run_command("ping"))
        assert(cursor:next())
      end

      drain(assert(database:run_cursor_command(
        bson.document({ { "find", "events" } })
      )))
      local closed = assert(database:run_cursor_command(
        bson.document({ { "find", "events" } })
      ))

      assert(database:run_command("ping"))
      assert.is_true(closed:close())
      drain(assert(collection:aggregate(bson.array({}))))
      drain(assert(database:aggregate(bson.array({}))))
      drain(assert(database:list_collections()))
      drain(assert(collection:list_indexes()))
      drain(assert(collection:list_search_indexes()))

      local stream = assert(collection:watch())

      assert(stream:next())
      assert(database:run_command("ping"))
      assert(stream:next())
      assert(client:close())
    end, function(peer, request)
      local name = request.body:keys()[1]

      if name == "ping" then
        assert.are_not.equal(active_connection, peer)
        return bson.document({ { "ok", 1 } })
      elseif name == "endSessions" then
        return bson.document({ { "ok", 1 } })
      elseif name == "getMore" then
        local cursor_id = request.body:get("getMore"):to_number()
        local cursor_state = assert(cursor_connections[cursor_id])

        assert.are.equal(cursor_state.connection, peer)
        active_connection = nil
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", cursor_state.namespace },
            { "nextBatch", bson.array({ cursor_state.document }) },
          }) },
        })
      elseif name == "killCursors" then
        local cursor_id = request.body:get("cursors"):get(1):to_number()
        local cursor_state = assert(cursor_connections[cursor_id])

        assert.are.equal(cursor_state.connection, peer)
        active_connection = nil
        return bson.document({ { "ok", 1 } })
      end

      local namespace = "app.events"
      local document = bson.document({ { "n", next_cursor_id } })

      if name == "listCollections" then
        namespace = "app.$cmd.listCollections"
        document = bson.document({ { "name", "events" } })
      elseif name == "listIndexes" then
        document = bson.document({ { "name", "_id_" } })
      elseif name == "aggregate" then
        local pipeline = request.body:get("pipeline")
        local first_stage = #pipeline > 0 and pipeline:get(1) or nil

        if first_stage and first_stage:get("$changeStream") ~= nil then
          document = bson.document({
            { "_id", bson.document({ { "token", next_cursor_id } }) },
            { "operationType", "insert" },
          })
        elseif first_stage and first_stage:get("$listSearchIndexes") ~= nil then
          document = bson.document({ { "name", "search" } })
        elseif type(request.body:get("aggregate")) ~= "string" then
          namespace = "app.$cmd.aggregate"
        end
      end

      cursor_connections[next_cursor_id] = {
        connection = peer,
        document = document,
        namespace = namespace,
      }
      active_connection = peer
      local response = bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(next_cursor_id) },
          { "ns", namespace },
          { "firstBatch", bson.array({ document }) },
        }) },
      })

      next_cursor_id = next_cursor_id + 1
      return response
    end)
  end)

  it("reports a pinned cursor in load-balanced wait queue timeouts", function()
    local service_id = assert(bson.object_id("000000000000000000000001"))

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          max_pool_size = 1,
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
          wait_queue_timeout_ms = 50,
        }
      ))
      local database = client:database()
      local cursor = assert(database:collection("events"):find())
      local response, err = database:run_command("ping")

      assert.is_nil(response)
      assert.matches(
        "maxPoolSize: 1, connections in use by cursors: 1, "
          .. "connections in use by transactions: 0, "
          .. "connections in use by other operations: 0",
        err.message,
        1,
        true
      )
      assert(cursor:close())
      assert(client:close())
    end, function(_, request)
      local name = request.body:keys()[1]

      if name == "find" then
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(42) },
            { "ns", "app.events" },
            { "firstBatch", bson.array({}) },
          }) },
        })
      end

      if name == "endSessions" then
        return bson.document({ { "ok", 1 } })
      end

      assert.are.equal("killCursors", name)
      return bson.document({ { "ok", 1 } })
    end)
  end)

  it("pins a load-balanced transaction through repeated commits", function()
    local service_id = assert(bson.object_id("000000000000000000000001"))
    local transaction_peer

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          max_pool_size = 2,
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local database = client:database()
      local collection = database:collection("events")
      local session = assert(client:start_session())

      assert(session:start_transaction())
      assert(collection:insert_one(
        bson.document({ { "n", 1 } }),
        { session = session }
      ))
      assert(database:run_command("ping"))
      assert(collection:insert_one(
        bson.document({ { "n", 2 } }),
        { session = session }
      ))

      for _ = 1, 4 do
        assert(session:commit_transaction())
      end

      assert.is_true(session:is_pinned())
      assert(session:unpin_connection())
      assert.is_false(session:is_pinned())
      assert(session:end_session())
      assert(client:close())
    end, function(peer, request)
      local name = request.body:keys()[1]

      if name == "ping" then
        assert.are_not.equal(transaction_peer, peer)
      elseif name == "insert" then
        if transaction_peer then
          assert.are.equal(transaction_peer, peer)
        else
          transaction_peer = peer
        end
      elseif name == "commitTransaction" then
        assert.are.equal(transaction_peer, peer)
      elseif name ~= "endSessions" then
        error("unexpected command: " .. name)
      end

      return bson.document({ { "ok", 1 }, { "n", 1 } })
    end)
  end)

  it("repins after starting a new load-balanced transaction", function()
    local service_id = assert(bson.object_id("000000000000000000000001"))
    local transaction_numbers = {}

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          max_pool_size = 1,
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local collection = client:database():collection("events")
      local session = assert(client:start_session())

      assert(session:start_transaction())
      assert(collection:insert_one(
        bson.document({ { "n", 1 } }),
        { session = session }
      ))
      assert(session:commit_transaction())
      assert.is_true(session:is_pinned())

      assert(session:start_transaction())
      assert.is_false(session:is_pinned())
      assert(collection:insert_one(
        bson.document({ { "n", 2 } }),
        { session = session }
      ))
      assert.is_true(session:is_pinned())
      assert(session:abort_transaction())
      assert.is_false(session:is_pinned())
      assert(session:end_session())
      assert(client:close())
    end, function(_, request)
      local name = request.body:keys()[1]

      if name == "insert" then
        assert.is_true(request.body:get("startTransaction"))
        transaction_numbers[#transaction_numbers + 1] =
          request.body:get("txnNumber")
      elseif name ~= "commitTransaction" and name ~= "abortTransaction"
          and name ~= "endSessions"
      then
        error("unexpected command: " .. name)
      end

      return bson.document({ { "ok", 1 }, { "n", 1 } })
    end)

    assert.are.equal(2, #transaction_numbers)
    assert.are_not.equal(transaction_numbers[1], transaction_numbers[2])
  end)

  it("unpins for a non-transaction session operation", function()
    local service_id = assert(bson.object_id("000000000000000000000001"))
    local transaction_lsid

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          max_pool_size = 1,
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local database = client:database()
      local collection = database:collection("events")
      local session = assert(client:start_session())

      assert(session:start_transaction())
      assert(collection:insert_one(
        bson.document({ { "n", 1 } }),
        { session = session }
      ))
      assert(session:commit_transaction())
      assert.is_true(session:is_pinned())
      assert(database:run_command("ping", { session = session }))
      assert.is_false(session:is_pinned())
      assert(session:end_session())
      assert(client:close())
    end, function(_, request)
      local name = request.body:keys()[1]

      if name == "insert" then
        transaction_lsid = assert(bson.encode(request.body:get("lsid")))
      elseif name == "ping" then
        assert.are.equal(
          transaction_lsid,
          assert(bson.encode(request.body:get("lsid")))
        )
        assert.is_nil(request.body:get("txnNumber"))
        assert.is_nil(request.body:get("autocommit"))
      elseif name ~= "commitTransaction" and name ~= "endSessions" then
        error("unexpected command: " .. name)
      end

      return bson.document({ { "ok", 1 }, { "n", 1 } })
    end)
  end)

  it("applies ordinary transaction-error pin lifecycles", function()
    local service_id = assert(bson.object_id("000000000000000000000001"))
    local transaction_peer

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local database = client:database()
      local collection = database:collection("events")
      local session = assert(client:start_session())

      assert(session:start_transaction())
      assert(collection:insert_one(
        bson.document({ { "n", 1 } }),
        { session = session }
      ))
      local result, err = collection:update_one(
        bson.document({ { "n", 1 } }),
        bson.document({ { "$set", bson.document({ { "seen", true } }) } }),
        { session = session }
      )

      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.is_true(session:is_pinned())
      result, err = session:commit_transaction()
      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.is_true(session:is_pinned())
      assert(session:unpin_connection())

      transaction_peer = nil
      assert(session:start_transaction())
      assert(collection:insert_one(
        bson.document({ { "n", 2 } }),
        { session = session }
      ))
      assert(session:abort_transaction())
      assert.is_false(session:is_pinned())
      assert(database:run_command("ping"))
      assert(session:end_session())
      assert(client:close())
    end, function(peer, request)
      local name = request.body:keys()[1]

      if name == "insert" then
        transaction_peer = peer
      elseif name == "update" or name == "commitTransaction"
          or name == "abortTransaction"
      then
        assert.are.equal(transaction_peer, peer)
        return bson.document({
          { "ok", 0 },
          { "code", name == "abortTransaction" and 51 or 123 },
          { "errmsg", "transaction command rejected" },
        })
      elseif name ~= "ping" and name ~= "endSessions" then
        error("unexpected command: " .. name)
      end

      return bson.document({ { "ok", 1 }, { "n", 1 } })
    end)
  end)

  it("discards a transient network transaction pin", function()
    local failed_peer
    local service_id = assert(bson.object_id("000000000000000000000001"))

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          max_pool_size = 1,
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local database = client:database()
      local collection = database:collection("events")
      local session = assert(client:start_session())

      assert(session:start_transaction())
      assert(collection:insert_one(
        bson.document({ { "n", 1 } }),
        { session = session }
      ))
      local result, err = collection:update_one(
        bson.document({ { "n", 1 } }),
        bson.document({ { "$set", bson.document({ { "seen", true } }) } }),
        { session = session }
      )

      assert.is_nil(result)
      assert.is_true(err:has_label("TransientTransactionError"))
      assert.is_false(session:is_pinned())
      assert(session:abort_transaction())
      assert.is_false(session:is_pinned())
      assert(database:run_command("ping"))
      assert(session:end_session())
      assert(client:close())
    end, function(peer, request)
      local name = request.body:keys()[1]

      if name == "insert" then
        failed_peer = peer
      elseif name == "update" then
        assert.are.equal(failed_peer, peer)
        return nil
      elseif name == "abortTransaction" then
        assert.are_not.equal(failed_peer, peer)
      elseif name ~= "ping" and name ~= "endSessions" then
        error("unexpected command: " .. name)
      end

      return bson.document({ { "ok", 1 }, { "n", 1 } })
    end)
  end)

  it("releases a load-balanced pin after a network abort", function()
    local abort_count = 0
    local failed_peer
    local retry_peer
    local service_id = assert(bson.object_id("000000000000000000000001"))

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          max_pool_size = 1,
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local database = client:database()
      local collection = database:collection("events")
      local session = assert(client:start_session())

      assert(session:start_transaction())
      assert(collection:insert_one(
        bson.document({ { "n", 1 } }),
        { session = session }
      ))
      assert(session:abort_transaction())
      assert.are.equal(2, abort_count)
      assert.is_false(session:is_pinned())
      assert(database:run_command("ping"))
      assert(session:end_session())
      assert(client:close())
    end, function(peer, request)
      local name = request.body:keys()[1]

      if name == "insert" then
        failed_peer = peer
      elseif name == "abortTransaction" then
        abort_count = abort_count + 1

        if abort_count == 1 then
          assert.are.equal(failed_peer, peer)
          return nil
        end

        retry_peer = peer
        assert.are_not.equal(failed_peer, retry_peer)
      elseif name == "ping" then
        assert.are.equal(retry_peer, peer)
      elseif name ~= "endSessions" then
        error("unexpected command: " .. name)
      end

      return bson.document({ { "ok", 1 }, { "n", 1 } })
    end)
  end)

  it("retries commit on a fresh load-balanced connection", function()
    local commit_count = 0
    local failed_peer
    local retry_peer
    local service_id = assert(bson.object_id("000000000000000000000001"))

    run_endpoint(true, service_id, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          max_pool_size = 1,
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      ))
      local database = client:database()
      local collection = database:collection("events")
      local session = assert(client:start_session())

      assert(session:start_transaction())
      assert(collection:insert_one(
        bson.document({ { "n", 1 } }),
        { session = session }
      ))
      assert(session:commit_transaction())
      assert.are.equal(2, commit_count)
      assert.is_true(session:is_pinned())
      assert(session:unpin_connection())
      assert(database:run_command("ping"))
      assert(session:end_session())
      assert(client:close())
    end, function(peer, request)
      local name = request.body:keys()[1]

      if name == "insert" then
        failed_peer = peer
      elseif name == "commitTransaction" then
        commit_count = commit_count + 1

        if commit_count == 1 then
          assert.are.equal(failed_peer, peer)
          return nil
        end

        retry_peer = peer
        assert.are_not.equal(failed_peer, retry_peer)
      elseif name == "ping" then
        assert.are.equal(retry_peer, peer)
      elseif name ~= "endSessions" then
        error("unexpected command: " .. name)
      end

      return bson.document({ { "ok", 1 }, { "n", 1 } })
    end)
  end)

  it("runs the exact non-load-balanced connection-establishment cases", function()
    local fixture = load_fixture()
    local first = fixture:get("tests"):get(1)
    local expected_message = first:get("operations"):get(1)
      :get("expectError"):get("errorContains")

    assert.is_true(fixture_option(fixture, "lbTrueClient"))
    assert.is_false(fixture_option(fixture, "lbFalseClient"))

    run_endpoint(true, nil, function(port)
      local client, err = mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=true",
        {
          runtime = mongodb.runtime.copas(),
          server_selection_timeout_ms = 2000,
        }
      )

      assert.is_nil(client)
      assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
      assert.is_truthy(err.message:find(expected_message, 1, true))
    end)

    run_endpoint(false, nil, function(port)
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?loadBalanced=false",
        { runtime = mongodb.runtime.copas() }
      ))

      assert(client:database():run_command("ping"))
      assert(client:close())
    end)
  end)
end)
