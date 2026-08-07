local bson = require("mongodb.bson")
local copas = require("copas")
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

describe("retryable reads over OP_MSG", function()
  it("reconnects once while preserving the session and monitoring operation", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local connection_count = 0
    local first_lsid
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
          "mongodb://127.0.0.1:" .. port .. "/app",
          {
            command_listeners = { listener },
            runtime = mongodb.runtime.copas(),
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
