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
    request_id = 700 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("MONGODB-OIDC command execution", function()
  it("authenticates once before an application command", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(client)
      client = copas.wrap(client)
      local handshake = receive_frame(client)

      send_response(client, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local start = receive_frame(client)
      local payload = assert(bson.decode(start.body:get("payload").data))

      assert.are.equal("saslStart", start.body:keys()[1])
      assert.are.equal("MONGODB-OIDC", start.body:get("mechanism"))
      assert.are.equal("private-access-token", payload:get("jwt"))
      send_response(client, start, bson.document({
        { "conversationId", 1 },
        { "payload", bson.binary("") },
        { "done", true },
        { "ok", 1 },
      }))

      local ping = receive_frame(client)

      assert.are.equal("ping", ping.body:keys()[1])
      send_response(client, ping, bson.document({ { "ok", 1 } }))
      client:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local callbacks = 0
        local client = assert(mongodb.client(
          "mongodb://machine-user@127.0.0.1:" .. port
            .. "/admin?authMechanism=MONGODB-OIDC",
          {
            auth_mechanism_properties = {
              OIDC_CALLBACK = function(context)
                callbacks = callbacks + 1
                assert.are.equal("machine-user", context.username)
                return { access_token = "private-access-token" }
              end,
            },
          }
        ))

        assert(client:database():run_command("ping"))
        assert.are.equal(1, callbacks)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    assert.is_table(outcome)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("runs a human callback between principal and JWT SASL steps", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(client)
      client = copas.wrap(client)
      local handshake = receive_frame(client)

      send_response(client, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local start = receive_frame(client)
      local principal = assert(bson.decode(start.body:get("payload").data))
      local idp_payload = assert(bson.encode(bson.document({
        { "issuer", "https://issuer.example.com" },
        { "clientId", "client-id" },
        { "requestScopes", bson.array({ "openid" }) },
      })))

      assert.are.equal("saslStart", start.body:keys()[1])
      assert.are.equal("human-user", principal:get("n"))
      send_response(client, start, bson.document({
        { "conversationId", 7 },
        { "payload", bson.binary(idp_payload) },
        { "done", false },
        { "ok", 1 },
      }))

      local continue = receive_frame(client)
      local token = assert(bson.decode(continue.body:get("payload").data))

      assert.are.equal("saslContinue", continue.body:keys()[1])
      assert.are.equal(7, continue.body:get("conversationId"):to_number())
      assert.are.equal("private-access-token", token:get("jwt"))
      send_response(client, continue, bson.document({
        { "conversationId", 7 },
        { "payload", bson.binary("") },
        { "done", true },
        { "ok", 1 },
      }))

      local ping = receive_frame(client)

      assert.are.equal("ping", ping.body:keys()[1])
      send_response(client, ping, bson.document({ { "ok", 1 } }))
      client:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local callbacks = 0
        local client = assert(mongodb.client(
          "mongodb://human-user@127.0.0.1:" .. port
            .. "/admin?authMechanism=MONGODB-OIDC",
          {
            auth_mechanism_properties = {
              OIDC_HUMAN_CALLBACK = function(context)
                callbacks = callbacks + 1
                assert.are.equal(300, context.timeout_seconds)
                assert.are.equal(
                  "https://issuer.example.com",
                  context.idp_info.issuer
                )
                assert.are.equal("client-id", context.idp_info.client_id)
                assert.are.same(
                  { "openid" },
                  context.idp_info.request_scopes
                )
                return {
                  access_token = "private-access-token",
                  refresh_token = "private-refresh-token",
                }
              end,
            },
          }
        ))

        assert(client:database():run_command("ping"))
        assert.are.equal(1, callbacks)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    assert.is_table(outcome)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("rejects a human callback host before token or SASL activity", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(client)
      client = copas.wrap(client)
      local handshake = receive_frame(client)

      send_response(client, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local bytes, reason = client:receive(4)

      assert.is_nil(bytes)
      assert.are.equal("closed", reason)
      client:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local callbacks = 0
        local client, err = mongodb.client(
          "mongodb://127.0.0.1:" .. port
            .. "/admin?authMechanism=MONGODB-OIDC",
          {
            auth_mechanism_properties = {
              ALLOWED_HOSTS = { "login.example.com" },
              OIDC_HUMAN_CALLBACK = function()
                callbacks = callbacks + 1
              end,
            },
          }
        )

        assert.is_nil(client)
        assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
        assert.are.equal(
          "MONGODB-OIDC human callback host is not allowed",
          err.message
        )
        assert.are.equal(0, callbacks)
      end))
      copas.removeserver(server)
    end)

    assert.is_table(outcome)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
