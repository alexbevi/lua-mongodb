local bson = require("mongodb.bson")
local copas = require("copas")
local mongodb = require("mongodb")
local op_msg = require("mongodb.wire.op_msg")
local socket = require("socket")

local ENTROPY = string.pack(
  ">I4I4I4I4I4I4I4I4",
  0x00010203,
  0x04050607,
  0x08090a0b,
  0x0c0d0e0f,
  0x10111213,
  0x14151617,
  0x18191a1b,
  0x1c1d1e1f
)
local NONCE = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

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
    request_id = 8000 + request.request_id,
    response_to = request.request_id,
  }))))
end

local function hello_response()
  return bson.document({
    { "ok", 1 },
    { "helloOk", true },
    { "isWritablePrimary", true },
    { "logicalSessionTimeoutMinutes", 30 },
    { "maxWireVersion", 25 },
  })
end

local function auth_hello_response()
  local entries = hello_response():entries()

  entries[#entries + 1] = {
    "saslSupportedMechs",
    bson.array({ "SCRAM-SHA-256", "SCRAM-SHA-1" }),
  }
  return bson.document(entries)
end

local function auth_replica_set_hello_response(address)
  local entries = auth_hello_response():entries()

  entries[#entries + 1] = { "setName", "rs" }
  entries[#entries + 1] = { "hosts", bson.array({ address }) }
  entries[#entries + 1] = { "primary", address }
  return bson.document(entries)
end

local function complete_authentication(peer, connection_count, failure)
  local start = receive_frame(peer)

  assert.are.equal("saslStart", start.body:keys()[1])
  send_response(peer, start, bson.document({
    { "conversationId", 1 },
    { "payload", bson.binary(
      "r=" .. NONCE .. "server-suffix,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
    ) },
    { "done", false },
    { "ok", 1 },
  }))
  local continue = receive_frame(peer)

  assert.are.equal("saslContinue", continue.body:keys()[1])

  if connection_count == 2 then
    if failure == "network" then
      peer:close()
    else
      send_response(peer, continue, bson.document({
        { "ok", 0 },
        { "code", 91 },
        { "codeName", "ShutdownInProgress" },
        { "errmsg", "shutdown in progress" },
      }))
      peer:close()
    end

    return false
  end

  send_response(peer, continue, bson.document({
    { "conversationId", 1 },
    { "payload", bson.binary(
      "v=ULVJCzOWFs0L7wP6UkjMKgjZGBcBDyOfKFh3lKC0cXk="
    ) },
    { "done", true },
    { "ok", 1 },
  }))
  return true
end

local function exercise_authenticated_handshake_retry(failure)
  local server = assert(socket.bind("127.0.0.1", 0))
  local _, port = assert(server:getsockname())
  local connection_count = 0
  local events = {}
  local outcome
  local server_error
  local listener = {}

  local function record(_, event)
    if event.command_name == "ping" or event.command_name == "find" then
      events[#events + 1] = event
    end
  end

  listener.failed = record
  listener.started = record
  listener.succeeded = record
  port = assert(math.tointeger(port))
  copas.addserver(server, function(peer)
    local ok, err = pcall(function()
      peer = copas.wrap(peer)
      connection_count = connection_count + 1
      local handshake = receive_frame(peer)

      assert.are.equal("admin.user", handshake.body:get("saslSupportedMechs"))
      send_response(peer, handshake, auth_hello_response())

      if not complete_authentication(peer, connection_count, failure) then
        return
      end

      local command = receive_frame(peer)

      if connection_count == 1 then
        assert.are.equal("ping", command.body:keys()[1])
        peer:close()
        return
      end

      assert.are.equal(3, connection_count)
      assert.are.equal("find", command.body:keys()[1])
      send_response(peer, command, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "admin.items" },
          { "firstBatch", bson.array({
            bson.document({ { "_id", 1 }, { "value", failure } }),
          }) },
        }) },
      }))
      peer:close()
    end)

    if not ok then
      server_error = err
      pcall(peer.close, peer)
    end
  end)

  copas.loop(function()
    outcome = table.pack(pcall(function()
      local client = assert(mongodb.client(
        "mongodb://user:pencil@127.0.0.1:" .. port .. "/admin",
        {
          command_listeners = { listener },
          runtime = mongodb.runtime.copas({
            entropy = {
              bytes = function(_, count)
                assert.is_true(count == 16 or count == 32)
                return ENTROPY:sub(1, count)
              end,
            },
          }),
        }
      ))
      local ping, ping_err = client:database():run_command("ping")

      assert.is_nil(ping)
      assert.is_not_nil(ping_err)
      local item = assert(client:database():collection("items"):find_one(
        bson.document({ { "_id", 1 } })
      ))

      assert.are.equal(failure, item:get("value"))
      assert.are.equal(3, connection_count)
      assert.are.same(
        { "command_started", "command_failed", "command_started", "command_succeeded" },
        { events[1].type, events[2].type, events[3].type, events[4].type }
      )
      assert.are.equal("ping", events[1].command_name)
      assert.are.equal("find", events[3].command_name)
      assert(client:close())
    end))
    copas.removeserver(server)
  end)

  if not outcome[1] then
    error(outcome[2], 0)
  end

  if server_error then
    error(server_error, 0)
  end
end

local function exercise_authenticated_write_handshake_retry(failure)
  local server = assert(socket.bind("127.0.0.1", 0))
  local _, port = assert(server:getsockname())
  local connection_count = 0
  local events = {}
  local outcome
  local server_error
  local listener = {}

  local function record(_, event)
    if event.command_name == "ping" or event.command_name == "insert" then
      events[#events + 1] = event
    end
  end

  listener.failed = record
  listener.started = record
  listener.succeeded = record
  port = assert(math.tointeger(port))
  local address = "127.0.0.1:" .. port

  copas.addserver(server, function(peer)
    local ok, err = pcall(function()
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)
      local application = handshake.body:get("saslSupportedMechs") ~= nil

      send_response(
        peer,
        handshake,
        auth_replica_set_hello_response(address)
      )

      if not application then
        while true do
          local received, request = pcall(receive_frame, peer)

          if not received then
            break
          end

          assert.is_true(
            request.body:keys()[1] == "hello"
              or request.body:keys()[1] == "ismaster"
          )
          send_response(
            peer,
            request,
            auth_replica_set_hello_response(address)
          )
        end

        return
      end

      connection_count = connection_count + 1
      assert.are.equal("admin.user", handshake.body:get("saslSupportedMechs"))

      if not complete_authentication(peer, connection_count, failure) then
        return
      end

      local command = receive_frame(peer)

      if connection_count == 1 then
        assert.are.equal("ping", command.body:keys()[1])
        peer:close()
        return
      end

      assert.are.equal(3, connection_count)
      assert.are.equal("insert", command.body:keys()[1])
      assert.are.equal(bson.int64(1), command.body:get("txnNumber"))
      assert.is_true(bson.is_document(command.body:get("lsid")))
      send_response(peer, command, bson.document({
        { "ok", 1 },
        { "n", 1 },
      }))
      peer:close()
    end)

    if not ok then
      server_error = err
      pcall(peer.close, peer)
    end
  end)

  copas.loop(function()
    outcome = table.pack(pcall(function()
      local client = assert(mongodb.client(
        "mongodb://user:pencil@" .. address .. "/admin?replicaSet=rs",
        {
          command_listeners = { listener },
          heartbeat_frequency_ms = 500,
          runtime = mongodb.runtime.copas({
            entropy = {
              bytes = function(_, count)
                assert.is_true(count == 16 or count == 32)
                return ENTROPY:sub(1, count)
              end,
            },
          }),
        }
      ))
      local ping, ping_err = client:database():run_command("ping")

      assert.is_nil(ping)
      assert.is_not_nil(ping_err)
      local result = assert(client:database():collection("items"):insert_many({
        bson.document({ { "_id", failure } }),
      }))

      assert.are.equal(failure, result.inserted_ids[1])
      assert.are.equal(3, connection_count)
      assert.are.same(
        { "command_started", "command_failed", "command_started", "command_succeeded" },
        { events[1].type, events[2].type, events[3].type, events[4].type }
      )
      assert.are.equal("ping", events[1].command_name)
      assert.are.equal("insert", events[3].command_name)
      assert(client:close())
    end))
    copas.removeserver(server)
  end)

  if not outcome[1] then
    error(outcome[2], 0)
  end

  if server_error then
    error(server_error, 0)
  end
end

local function exercise_authenticated_transaction_handshake_retry(command_name)
  assert.is_true(
    command_name == "abortTransaction" or command_name == "commitTransaction"
  )
  local server = assert(socket.bind("127.0.0.1", 0))
  local _, port = assert(server:getsockname())
  local connection_count = 0
  local events = {}
  local first_lsid
  local first_txn_number
  local client
  local outcome
  local server_error
  local listener = {}
  local transaction_state = command_name == "commitTransaction"
    and "committed" or "aborted"

  local function record(_, event)
    if event.command_name == command_name
        or event.command_name == "insert" or event.command_name == "ping"
    then
      events[#events + 1] = event
    end
  end

  listener.failed = record
  listener.started = record
  listener.succeeded = record
  port = assert(math.tointeger(port))
  local address = "127.0.0.1:" .. port

  copas.addserver(server, function(peer)
    local ok, err = pcall(function()
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)
      local application = handshake.body:get("saslSupportedMechs") ~= nil

      send_response(peer, handshake, auth_replica_set_hello_response(address))

      if not application then
        while true do
          local received, request = pcall(receive_frame, peer)

          if not received then
            break
          end

          assert.is_true(
            request.body:keys()[1] == "hello"
              or request.body:keys()[1] == "ismaster"
          )
          send_response(
            peer,
            request,
            auth_replica_set_hello_response(address)
          )
        end

        return
      end

      connection_count = connection_count + 1
      assert.are.equal("admin.user", handshake.body:get("saslSupportedMechs"))

      if not complete_authentication(peer, connection_count, "network") then
        return
      end

      local command = receive_frame(peer)

      if connection_count == 1 then
        assert.are.equal("insert", command.body:keys()[1])
        assert.is_true(command.body:get("startTransaction"))
        first_lsid = assert(bson.encode(command.body:get("lsid")))
        first_txn_number = command.body:get("txnNumber")
        send_response(peer, command, bson.document({ { "ok", 1 }, { "n", 1 } }))

        local ping = receive_frame(peer)

        assert.are.equal("ping", ping.body:keys()[1])
        peer:close()
        return
      end

      assert.are.equal(3, connection_count)
      assert.are.equal(command_name, command.body:keys()[1])
      assert.are.equal(first_lsid, assert(bson.encode(command.body:get("lsid"))))
      assert.are.equal(first_txn_number, command.body:get("txnNumber"))
      assert.is_false(command.body:get("autocommit"))

      if command_name == "commitTransaction" then
        local write_concern = command.body:get("writeConcern")

        assert.are.equal("majority", write_concern:get("w"))
        assert.are.equal(10000, write_concern:get("wtimeout"):to_number())
      end

      send_response(peer, command, bson.document({ { "ok", 1 } }))
      peer:close()
    end)

    if not ok then
      server_error = err
      pcall(peer.close, peer)
    end
  end)

  copas.loop(function()
    outcome = table.pack(pcall(function()
      client = assert(mongodb.client(
        "mongodb://user:pencil@" .. address
          .. "/admin?replicaSet=rs&retryWrites=false",
        {
          command_listeners = { listener },
          heartbeat_frequency_ms = 500,
          runtime = mongodb.runtime.copas({
            entropy = {
              bytes = function(_, count)
                assert.is_true(count == 16 or count == 32)
                return ENTROPY:sub(1, count)
              end,
            },
          }),
        }
      ))
      local database = assert(client:database())
      local session0 = assert(client:start_session())
      local session1 = assert(client:start_session())

      assert(session0:start_transaction())
      assert(database:collection("items"):insert_one(
        bson.document({ { "_id", 1 } }),
        { session = session0 }
      ))
      local ping, ping_err = database:run_command("ping", { session = session1 })

      assert.is_nil(ping)
      assert.is_not_nil(ping_err)

      if command_name == "commitTransaction" then
        assert(session0:commit_transaction())
      else
        assert(session0:abort_transaction())
      end

      assert.are.equal(transaction_state, session0:get_transaction_state())
      assert.are.equal(3, connection_count)
      assert.are.same(
        {
          "command_started",
          "command_succeeded",
          "command_started",
          "command_failed",
          "command_started",
          "command_succeeded",
        },
        {
          events[1].type,
          events[2].type,
          events[3].type,
          events[4].type,
          events[5].type,
          events[6].type,
        }
      )
      assert.are.equal("insert", events[1].command_name)
      assert.are.equal("ping", events[3].command_name)
      assert.are.equal(command_name, events[5].command_name)
      assert(session0:end_session())
      assert(session1:end_session())
    end))

    if client then
      local closed, close_err = client:close()

      if outcome[1] and not closed then
        outcome = table.pack(false, close_err)
      end
    end

    copas.removeserver(server)
  end)

  if server_error then
    error(server_error, 0)
  end

  if not outcome[1] then
    error(outcome[2], 0)
  end
end

describe("retryable reads over OP_MSG", function()
  it("recovers from network and shutdown errors during authentication", function()
    for _, failure in ipairs({ "network", "shutdown" }) do
      exercise_authenticated_handshake_retry(failure)
    end
  end)

  it("reconnects once while preserving the session and monitoring operation", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local connection_count = 0
    local first_lsid
    local first_metadata
    local outcome
    local server_error
    local events = {}
    local listener = {}

    local function record(_, event)
      if event.command_name == "find" then
        events[#events + 1] = event
      end
    end

    listener.failed = record
    listener.started = record
    listener.succeeded = record

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      local ok, err = pcall(function()
        peer = copas.wrap(peer)
        connection_count = connection_count + 1
        local handshake = receive_frame(peer)
        local metadata = assert(handshake.body:get("client"))

        assert.are.equal("retry-spec", metadata:get("application"):get("name"))
        assert.are.equal("test-os", metadata:get("os"):get("type"))
        assert.are.equal("Lua 5.4 retry-runtime", metadata:get("platform"))

        if first_metadata == nil then
          first_metadata = assert(bson.encode(metadata))
        else
          assert.are.equal(first_metadata, assert(bson.encode(metadata)))
        end

        send_response(peer, handshake, hello_response())
        local find = receive_frame(peer)

        assert.are.equal("find", find.body:get_at(1))

        if connection_count == 1 then
          first_lsid = assert(bson.encode(find.body:get("lsid")))
          peer:close()
          return
        end

        assert.are.equal(first_lsid, assert(bson.encode(find.body:get("lsid"))))
        send_response(peer, find, bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "app.items" },
            { "firstBatch", bson.array({
              bson.document({ { "_id", 1 }, { "value", "retried" } }),
            }) },
          }) },
        }))
        peer:close()
      end)

      if not ok then
        server_error = err
        pcall(peer.close, peer)
      end
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app?appName=retry-spec",
          {
            command_listeners = { listener },
            runtime = mongodb.runtime.copas({
              metadata = {
                os = { type = "test-os" },
                platform = "Lua 5.4 retry-runtime",
              },
            }),
          }
        ))
        local item = assert(client:database():collection("items"):find_one(
          bson.document({ { "_id", 1 } })
        ))

        assert.are.equal("retried", item:get("value"))
        assert.are.equal(2, connection_count)
        assert.are.equal(4, #events)
        assert.are.same(
          { "command_started", "command_failed", "command_started", "command_succeeded" },
          { events[1].type, events[2].type, events[3].type, events[4].type }
        )
        assert.are.equal(events[1].operation_id, events[3].operation_id)
        assert(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end

    if server_error then
      error(server_error, 0)
    end
  end)
end)

describe("retryable writes over OP_MSG", function()
  it("recovers from network and shutdown errors during authentication", function()
    for _, failure in ipairs({ "network", "shutdown" }) do
      exercise_authenticated_write_handshake_retry(failure)
    end
  end)
end)

describe("transaction retries over OP_MSG", function()
  it("retries abort after a network failure during authentication", function()
    exercise_authenticated_transaction_handshake_retry("abortTransaction")
  end)

  it("retries commit after a network failure during authentication", function()
    exercise_authenticated_transaction_handshake_retry("commitTransaction")
  end)
end)
