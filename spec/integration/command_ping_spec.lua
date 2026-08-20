local bson = require("mongodb.bson")
local command_executor = require("mongodb.command.executor")
local copas = require("copas")
local op_compressed = require("mongodb.wire.op_compressed")
local op_msg = require("mongodb.wire.op_msg")
local runtime = require("mongodb.runtime")
local runtime_snappy = require("mongodb.runtime.snappy")
local runtime_zlib = require("mongodb.runtime.zlib")
local runtime_zstandard = require("mongodb.runtime.zstandard")
local socket = require("socket")
local transport = require("mongodb.network.transport")

local function receive_frame(client, compression)
  local header = assert(client:receive(4))
  local size = string.unpack("<i4", header)
  local bytes = header .. assert(client:receive(size - 4))
  local op_code = string.unpack("<i4", bytes, 13)

  if op_code == op_compressed.OP_CODE then
    bytes = assert(op_compressed.decode(bytes, { compression = compression }))
  end

  return bytes, op_code
end

local function send_response(client, request, body)
  local response = assert(op_msg.encode({
    body = body,
    direction = "response",
    request_id = 700 + request.request_id,
    response_to = request.request_id,
  }))

  assert(client:send(response))
end

local function assert_compressed_ping(name, provider, command_options)
  local compression = { [name] = provider }
  local server = assert(socket.bind("127.0.0.1", 0))
  local _, port = assert(server:getsockname())
  local outcome
  local server_error

  port = assert(math.tointeger(port))
  copas.addserver(server, function(client)
    local ok, err = pcall(function()
      client = copas.wrap(client)
      local handshake_bytes, handshake_op_code = receive_frame(client, compression)
      local handshake = assert(op_msg.decode(handshake_bytes, {
        direction = "request",
      }))

      assert.are.equal(op_msg.OP_CODE, handshake_op_code)
      assert.are.same({ name }, handshake.body:get("compression"):values())
      send_response(client, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
        { "compression", bson.array({ name }) },
      }))

      local ping_bytes, ping_op_code = receive_frame(client, compression)
      local ping = assert(op_msg.decode(ping_bytes, { direction = "request" }))

      assert.are.equal(op_compressed.OP_CODE, ping_op_code)
      assert.are.equal("ping", ping.body:keys()[1])
      send_response(client, ping, bson.document({ { "ok", 1 } }))
      client:close()
    end)

    if not ok then
      server_error = err
      pcall(client.close, client)
    end
  end)

  copas.loop(function()
    outcome = table.pack(pcall(function()
      local adapter = runtime.copas({ compression = compression })
      local deadline = runtime.deadline_after(adapter, 2)
      local connection = assert(transport.connect(adapter, "127.0.0.1", port, {
        deadline = deadline,
      }))
      local options = {
        compression = compression,
        compressors = { name },
        server = "127.0.0.1:" .. port,
      }

      for key, value in pairs(command_options or {}) do
        options[key] = value
      end

      local commands = command_executor.new(connection, options)

      assert(commands:hello({ deadline = deadline }))
      assert(commands:command("admin", bson.document({ { "ping", 1 } }), {
        deadline = deadline,
      }))
      assert.is_true(commands:close())
    end))
    copas.removeserver(server)
  end)

  if server_error then
    error(server_error, 0)
  elseif not outcome[1] then
    error(outcome[2], 0)
  end
end

describe("standalone command execution", function()
  it("handshakes and pings over the Copas TCP adapter", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    port = assert(math.tointeger(port))
    local outcome

    copas.addserver(server, function(client)
      client = copas.wrap(client)
      local handshake = assert(op_msg.decode(receive_frame(client), { direction = "request" }))

      assert.are.equal("ismaster", handshake.body:keys()[1])
      send_response(client, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local ping = assert(op_msg.decode(receive_frame(client), { direction = "request" }))

      assert.are.equal("ping", ping.body:keys()[1])
      assert.are.equal("admin", ping.body:get("$db"))
      send_response(client, ping, bson.document({ { "ok", 1 } }))
      client:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local adapter = runtime.copas()
        local deadline = runtime.deadline_after(adapter, 2)
        local connection = assert(transport.connect(adapter, "127.0.0.1", port, {
          deadline = deadline,
        }))
        local commands = command_executor.new(connection, {
          server = "127.0.0.1:" .. port,
        })

        assert(commands:hello({ deadline = deadline }))
        assert(commands:command("admin", bson.document({ { "ping", 1 } }), {
          deadline = deadline,
        }))
        assert.is_true(commands:close())
      end))
      copas.removeserver(server)
    end)

    assert.is_table(outcome)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("negotiates zlib and sends an eligible ping as OP_COMPRESSED", function()
    local provider = assert(runtime_zlib.load())

    assert_compressed_ping("zlib", provider, { zlib_compression_level = 6 })
  end)

  it("negotiates Snappy and sends an eligible ping with compressor id 1", function()
    local provider = assert(runtime_snappy.load())

    assert.are.equal(1, provider.compressor_id)
    assert_compressed_ping("snappy", provider)
  end)

  it("negotiates Zstandard and sends an eligible ping with compressor id 3", function()
    local provider = assert(runtime_zstandard.load())

    assert.are.equal(3, provider.compressor_id)
    assert_compressed_ping("zstd", provider)
  end)
end)
