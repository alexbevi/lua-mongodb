local bson = require("mongodb.bson")
local copas = require("copas")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local mongodb = require("mongodb")
local op_msg = require("mongodb.wire.op_msg")
local socket = require("socket")

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

describe("initial DNS seedlist client bootstrap", function()
  it("opens the resolved seed only after SRV and TXT succeed", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local dns = fake_runtime.new()
    local runtime = mongodb.runtime.copas({ dns = dns.dns })
    local connect = runtime.socket.connect
    local connected_hosts = {}
    local outcome

    port = assert(math.tointeger(port))

    dns:queue_dns("srv", {
      { port = port, target = "db.example.com", ttl = 60 },
    })
    dns:queue_dns("txt", {
      { strings = { "replicaSet=rs0" }, ttl = 60 },
    })
    runtime.socket.connect = function(capability, host, target_port, options, deadline, token)
      connected_hosts[#connected_hosts + 1] = host
      return connect(capability, "127.0.0.1", target_port, options, deadline, token)
    end

    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local initial_hello = true

      while true do
        local received, request = pcall(receive_frame, peer)

        if not received then
          break
        end

        local command_name = request.body:keys()[1]

        if command_name == "hello" or command_name == "ismaster" then
          send_response(peer, request, bson.document({
            { "ok", 1 },
            { "helloOk", true },
            { "isWritablePrimary", true },
            { "setName", "rs0" },
            { "hosts", bson.array({ "db.example.com:" .. port }) },
            { "maxWireVersion", 25 },
            { "logicalSessionTimeoutMinutes", 30 },
          }))
          initial_hello = false
        elseif command_name == "ping" or command_name == "endSessions" then
          send_response(peer, request, bson.document({ { "ok", 1 } }))
        else
          error("unexpected DNS seedlist command " .. tostring(command_name))
        end
      end

      assert.is_false(initial_hello)
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb+srv://cluster.example.com/app?tls=false",
          {
            runtime = runtime,
            server_selection_timeout_ms = 2000,
          }
        ))

        assert(client:database():run_command("ping"))
        assert.are.same({
          { name = "_mongodb._tcp.cluster.example.com", type = "srv" },
          { name = "cluster.example.com", type = "txt" },
        }, dns.calls.dns)
        assert.are.equal("db.example.com", connected_hosts[1])
        assert(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("never opens a MongoDB socket when TXT preprocessing fails", function()
    local runtime = fake_runtime.new()

    runtime:queue_dns("srv", {
      { port = 27017, target = "db.example.com", ttl = 60 },
    })
    runtime:queue_dns("txt", {
      { strings = { "socketTimeoutMS=500" }, ttl = 60 },
    })

    local client, err = mongodb.client("mongodb+srv://cluster.example.com", {
      runtime = runtime,
    })

    assert.is_nil(client)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.same({}, runtime.calls.connect)
    assert.are.same({}, runtime.calls.tls)
  end)
end)
