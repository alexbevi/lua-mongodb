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
