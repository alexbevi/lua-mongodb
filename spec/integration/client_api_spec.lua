local bson = require("mongodb.bson")
local copas = require("copas")
local errors = require("mongodb.error")
local mongodb = require("mongodb")
local op_msg = require("mongodb.wire.op_msg")
local socket = require("socket")

local function receive_frame(client)
  local header = assert(client:receive(4))
  local size = string.unpack("<i4", header)
  return assert(op_msg.decode(header .. assert(client:receive(size - 4)), {
    direction = "request",
  }))
end

local function send_response(client, request, body)
  assert(client:send(assert(op_msg.encode({
    body = body,
    direction = "response",
    request_id = 900 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("public standalone client API", function()
  it("connects, runs ping on the URI database, and closes predictably", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      assert.are.equal("ismaster", handshake.body:keys()[1])
      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local ping = receive_frame(peer)

      assert.are.equal("ping", ping.body:keys()[1])
      assert.are.equal("app", ping.body:get("$db"))
      send_response(peer, ping, bson.document({ { "ok", 1 } }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          { runtime = mongodb.runtime.copas() }
        ))
        local database = assert(client:database())
        local reply = assert(database:run_command("ping"))

        assert.are.equal(1, reply:get("ok"):to_number())
        assert.is_true(client:close())
        assert.is_false(client:close())

        local closed_reply, closed_err = database:run_command("ping")

        assert.is_nil(closed_reply)
        assert.is_true(errors.is(closed_err, errors.CATEGORY.CLIENT))
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("discovers a replica set and executes through the primary pool", function()
    local servers = {
      a = assert(socket.bind("127.0.0.1", 0)),
      b = assert(socket.bind("127.0.0.1", 0)),
    }
    local _, port_a = assert(servers.a:getsockname())
    local _, port_b = assert(servers.b:getsockname())
    local addresses = {
      a = "127.0.0.1:" .. assert(math.tointeger(port_a)),
      b = "127.0.0.1:" .. assert(math.tointeger(port_b)),
    }
    local ping_address
    local metadata_count = { a = 0, b = 0 }
    local outcome
    local function serve(name)
      return function(peer)
        peer = copas.wrap(peer)
        local initial_hello = true

        while true do
          local received, request = pcall(receive_frame, peer)

          if not received then
            break
          end

          local command_name = request.body:keys()[1]

          if command_name == "hello" or command_name == "ismaster" then
            local metadata = request.body:get("client")

            if initial_hello then
              assert.is_not_nil(metadata)
              assert.are.equal("replica-spec", metadata:get("application"):get("name"))
              assert.are.equal("replica-os", metadata:get("os"):get("type"))
              assert.are.equal("Lua 5.4 replica-runtime", metadata:get("platform"))
              assert.are.equal("aws.lambda", metadata:get("env"):get("name"))
              assert.are.equal(
                "kubernetes",
                metadata:get("env"):get("container"):get("orchestrator")
              )
              metadata_count[name] = metadata_count[name] + 1
              initial_hello = false
            else
              assert.is_nil(metadata)
            end

            if request.body:get("maxAwaitTimeMS") ~= nil then
              copas.pause(0.005)
            end

            send_response(peer, request, bson.document({
              { "ok", 1 },
              { "helloOk", true },
              { "isWritablePrimary", name == "b" },
              { "secondary", name == "a" },
              { "setName", "rs" },
              { "hosts", bson.array({ addresses.a, addresses.b }) },
              { "primary", addresses.b },
              { "minWireVersion", 21 },
              { "maxWireVersion", 25 },
            }))
          elseif command_name == "ping" then
            ping_address = name
            send_response(peer, request, bson.document({ { "ok", 1 } }))
          else
            error("unexpected replica-set command " .. tostring(command_name))
          end
        end

        peer:close()
      end
    end

    copas.addserver(servers.a, serve("a"))
    copas.addserver(servers.b, serve("b"))
    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://" .. addresses.a .. "," .. addresses.b
            .. "/app?replicaSet=rs&appName=replica-spec",
          {
            heartbeat_frequency_ms = 500,
            runtime = mongodb.runtime.copas({
              lock_poll_interval = 0.001,
              metadata = {
                environment = {
                  AWS_EXECUTION_ENV = "AWS_Lambda_java8",
                  KUBERNETES_SERVICE_HOST = "1",
                },
                files = {},
                os = { type = "replica-os" },
                platform = "Lua 5.4 replica-runtime",
              },
            }),
            server_selection_timeout_ms = 2000,
          }
        ))
        local reply = assert(client:database():run_command("ping"))

        assert.are.equal(1, reply:get("ok"):to_number())
        assert.are.equal("b", ping_address)
        assert.is_true(metadata_count.a >= 1)
        assert.is_true(metadata_count.b >= 2)
        assert(client:close())
      end))
      copas.removeserver(servers.a)
      copas.removeserver(servers.b)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
