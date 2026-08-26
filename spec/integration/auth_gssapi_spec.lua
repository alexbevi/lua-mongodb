local bson = require("mongodb.bson")
local copas = require("copas")
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

local function sasl_response(payload, done)
  return bson.document({
    { "conversationId", 17 },
    { "payload", bson.binary(payload) },
    { "done", done },
    { "ok", 1 },
  })
end

describe("GSSAPI standalone authentication", function()
  it("authenticates through an injected runtime provider", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    port = assert(math.tointeger(port))
    local outcome
    local closed = 0

    copas.addserver(server, function(client)
      client = copas.wrap(client)
      local handshake = receive_frame(client)

      assert.is_nil(handshake.body:get("saslSupportedMechs"))
      send_response(client, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local start = receive_frame(client)

      assert.are.equal("saslStart", start.body:keys()[1])
      assert.are.equal("GSSAPI", start.body:get("mechanism"))
      assert.are.equal("client-one", start.body:get("payload").data)
      assert.are.equal(1, start.body:get("autoAuthorize"):to_number())
      assert.are.equal("$external", start.body:get("$db"))
      send_response(client, start, sasl_response("server-one", false))

      local context_continue = receive_frame(client)

      assert.are.equal("saslContinue", context_continue.body:keys()[1])
      assert.are.equal(17, context_continue.body:get("conversationId"):to_number())
      assert.are.equal("client-two", context_continue.body:get("payload").data)
      send_response(
        client,
        context_continue,
        sasl_response("server-layer", false)
      )

      local security_continue = receive_frame(client)

      assert.are.equal("saslContinue", security_continue.body:keys()[1])
      assert.are.equal("client-layer", security_continue.body:get("payload").data)
      send_response(client, security_continue, sasl_response("", true))

      local ping = receive_frame(client)

      assert.are.equal("ping", ping.body:keys()[1])
      send_response(client, ping, bson.document({ { "ok", 1 } }))
      client:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local runtime = mongodb.runtime.copas()
        local provider_step = 0

        runtime.gssapi = {
          create_context = function(_, options)
            assert.are.equal(
              "mongodb@127.0.0.1@EXAMPLE.COM",
              options.service_principal
            )
            assert.are.equal("user@EXAMPLE.COM", options.username)
            assert.is_nil(options.password)

            return {
              close = function()
                closed = closed + 1
                return true
              end,
              security_layer = function(_, challenge, username)
                assert.are.equal("server-layer", challenge)
                assert.are.equal("user@EXAMPLE.COM", username)
                return "client-layer"
              end,
              step = function(_, challenge)
                provider_step = provider_step + 1

                if provider_step == 1 then
                  assert.are.equal("", challenge)
                  return { complete = false, token = "client-one" }
                end

                assert.are.equal("server-one", challenge)
                return { complete = true, token = "client-two" }
              end,
            }
          end,
        }

        local client = assert(mongodb.client(
          "mongodb://user%40EXAMPLE.COM@127.0.0.1:" .. port
            .. "/?authMechanism=GSSAPI"
            .. "&authMechanismProperties=SERVICE_REALM:EXAMPLE.COM",
          { runtime = runtime }
        ))

        assert(client:database("admin"):run_command("ping"))
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    assert.is_table(outcome)

    if not outcome[1] then
      error(outcome[2], 0)
    end

    assert.are.equal(1, closed)
  end)
end)
