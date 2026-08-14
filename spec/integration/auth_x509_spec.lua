local bson = require("mongodb.bson")
local copas = require("copas")
local mongodb = require("mongodb")
local op_msg = require("mongodb.wire.op_msg")
local socket = require("socket")
local ssl = require("ssl")

local TLS_DIR = "spec/fixtures/tls/"

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

local function server_context()
  return assert(ssl.newcontext({
    cafile = TLS_DIR .. "ca.pem",
    certificate = TLS_DIR .. "server.pem",
    key = TLS_DIR .. "server-key.pem",
    mode = "server",
    options = { "all", "no_sslv2", "no_sslv3", "no_compression" },
    protocol = "any",
    verify = { "peer", "fail_if_no_peer_cert" },
  }))
end

describe("MONGODB-X509 standalone authentication", function()
  it("authenticates with a TLS client certificate before a command", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    port = assert(math.tointeger(port))
    local outcome

    copas.addserver(server, function(client)
      client = copas.wrap(client)
      assert(client:dohandshake(server_context()))
      local handshake = receive_frame(client)

      assert.is_nil(handshake.body:get("saslSupportedMechs"))
      send_response(client, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local authenticate = receive_frame(client)

      assert.are.equal("authenticate", authenticate.body:keys()[1])
      assert.are.equal("MONGODB-X509", authenticate.body:get("mechanism"))
      assert.is_nil(authenticate.body:get("user"))
      assert.are.equal("$external", authenticate.body:get("$db"))
      send_response(client, authenticate, bson.document({ { "ok", 1 } }))

      local ping = receive_frame(client)

      assert.are.equal("ping", ping.body:keys()[1])
      send_response(client, ping, bson.document({ { "ok", 1 } }))
      client:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/?authMechanism=MONGODB-X509",
          {
            tls = true,
            tls_ca_file = TLS_DIR .. "ca.pem",
            tls_certificate_key_file = TLS_DIR .. "client.pem",
            tls_certificate_key_file_password = "test-client-password",
          }
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
  end)
end)
