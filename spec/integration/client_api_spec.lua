local bson = require("mongodb.bson")
local copas = require("copas")
local errors = require("mongodb.error")
local mongodb = require("mongodb")
local op_compressed = require("mongodb.wire.op_compressed")
local op_msg = require("mongodb.wire.op_msg")
local runtime_zlib = require("mongodb.runtime.zlib")
local socket = require("socket")

local function decode_request(bytes, compression)
  local op_code = string.unpack("<i4", bytes, 13)

  if op_code == op_compressed.OP_CODE then
    bytes = assert(op_compressed.decode(bytes, { compression = compression }))
  end

  return assert(op_msg.decode(bytes, { direction = "request" })), op_code
end

local function receive_frame(client, compression)
  local header = assert(client:receive(4))
  local size = string.unpack("<i4", header)
  return decode_request(header .. assert(client:receive(size - 4)), compression)
end

local function receive_frame_or_closed(client, compression)
  local header, err = client:receive(4)

  if header == nil and err == "closed" then
    return nil
  end

  assert(header, err)
  local size = string.unpack("<i4", header)
  return decode_request(header .. assert(client:receive(size - 4)), compression)
end

local function send_response(client, request, body)
  assert(client:send(assert(op_msg.encode({
    body = body,
    direction = "response",
    request_id = 900 + request.request_id,
    response_to = request.request_id,
  }))))
end

local function assert_unavailable_compressor_warning(name, package_name, display_name)
  local server = assert(socket.bind("127.0.0.1", 0))
  local _, port = assert(server:getsockname())
  local outcome
  local server_error

  port = assert(math.tointeger(port))
  copas.addserver(server, function(peer)
    local ok, err = pcall(function()
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      assert.are.same({}, handshake.body:get("compression"):values())
      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))
    end)

    if not ok then
      server_error = err
    end

    peer:close()
  end)

  copas.loop(function()
    outcome = table.pack(pcall(function()
      local client = assert(mongodb.client(
        "mongodb://127.0.0.1:" .. port .. "/app?compressors=" .. name,
        { runtime = mongodb.runtime.copas({ compression = {} }) }
      ))

      assert.are.equal(1, #client.warnings)
      assert.are.equal(
        "wire protocol compression with " .. name .. " is not available; "
          .. "install " .. package_name .. " for " .. display_name .. " support",
        client.warnings[1]
      )
      assert(client:close())
    end))
    copas.removeserver(server)
  end)

  if server_error then
    error(server_error, 0)
  elseif not outcome[1] then
    error(outcome[2], 0)
  end
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

  it("omits unavailable configured Snappy and reports a client warning", function()
    assert_unavailable_compressor_warning("snappy", "lua-csnappy", "Snappy")
  end)

  it("omits unavailable configured Zstandard and reports a client warning", function()
    assert_unavailable_compressor_warning("zstd", "lua-zstd", "Zstandard")
  end)

  it("applies appended wrapper metadata only to new connections", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local connection_count = 0
    local outcome
    local server_error

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      local ok, err = pcall(function()
        peer = copas.wrap(peer)
        connection_count = connection_count + 1
        local handshake = receive_frame(peer)
        local client_metadata = assert(handshake.body:get("client"))
        local driver = client_metadata:get("driver")

        if connection_count == 1 then
          assert.are.equal("lua-mongodb|library", driver:get("name"))
          assert.are.equal("0.8.0|1.2", driver:get("version"))
          assert.are.equal(
            "Lua 5.4 wrapper-runtime|Library Platform",
            client_metadata:get("platform")
          )
        else
          assert.are.equal("lua-mongodb|library|framework", driver:get("name"))
          assert.are.equal("0.8.0|1.2|2.0", driver:get("version"))
          assert.are.equal(
            "Lua 5.4 wrapper-runtime|Library Platform|Framework Platform",
            client_metadata:get("platform")
          )
        end

        send_response(peer, handshake, bson.document({
          { "ok", 1 },
          { "helloOk", true },
          { "isWritablePrimary", true },
          { "maxWireVersion", 25 },
        }))

        if connection_count == 1 then
          for _ = 1, 2 do
            local ping = receive_frame(peer)

            assert.are.equal("ping", ping.body:keys()[1])
            send_response(peer, ping, bson.document({ { "ok", 1 } }))
          end
        else
          local find = receive_frame(peer)

          assert.are.equal("find", find.body:keys()[1])
          send_response(peer, find, bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(0) },
              { "ns", "app.items" },
              { "firstBatch", bson.array({
                bson.document({ { "_id", 1 }, { "value", "reconnected" } }),
              }) },
            }) },
          }))
        end

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
            driver_info = {
              name = "library",
              platform = "Library Platform",
              version = "1.2",
            },
            runtime = mongodb.runtime.copas({
              metadata = { platform = "Lua 5.4 wrapper-runtime" },
            }),
          }
        ))
        local database = assert(client:database())

        assert(database:run_command("ping"))
        assert.are.equal(1, connection_count)
        assert.is_false(client:append_metadata({
          name = "library",
          platform = "Library Platform",
          version = "1.2",
        }))
        assert.is_true(client:append_metadata({
          name = "framework",
          platform = "Framework Platform",
          version = "2.0",
        }))
        assert.are.equal(1, connection_count)
        assert(database:run_command("ping"))
        assert.are.equal(1, connection_count)
        assert.is_false(client:append_metadata({
          name = "framework",
          platform = "Framework Platform",
          version = "2.0",
        }))
        local item = assert(database:collection("items"):find_one(
          bson.document({ { "_id", 1 } })
        ))

        assert.are.equal("reconnected", item:get("value"))
        assert.are.equal(2, connection_count)
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

describe("public sharded client API", function()
  it("discovers mongos and executes a zlib-compressed command through it", function()
    local provider = assert(runtime_zlib.load())
    local compression = { zlib = provider }
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local compression_offers = 0
    local compressed_pings = 0
    local handshakes = 0
    local pings = 0
    local outcome
    local server_error

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      local ok, err = pcall(function()
        peer = copas.wrap(peer)

        while true do
          local request, op_code = receive_frame_or_closed(peer, compression)

          if request == nil then
            break
          end

          local name = request.body:keys()[1]

          if name == "hello" or name == "ismaster" then
            handshakes = handshakes + 1
            local entries = {
              { "ok", 1 },
              { "helloOk", true },
              { "isWritablePrimary", true },
              { "logicalSessionTimeoutMinutes", 30 },
              { "maxWireVersion", 25 },
              { "msg", "isdbgrid" },
            }

            if request.body:get("compression") ~= nil then
              assert.are.equal(op_msg.OP_CODE, op_code)
              assert.are.same(
                { "zlib" },
                request.body:get("compression"):values()
              )
              entries[#entries + 1] = {
                "compression",
                bson.array({ "zlib" }),
              }
              compression_offers = compression_offers + 1
            end

            send_response(peer, request, bson.document(entries))
          elseif name == "ping" then
            assert.are.equal(op_compressed.OP_CODE, op_code)
            compressed_pings = compressed_pings + 1
            pings = pings + 1
            send_response(peer, request, bson.document({ { "ok", 1 } }))
          elseif name == "endSessions" then
            send_response(peer, request, bson.document({ { "ok", 1 } }))
          else
            error("unexpected mongos command " .. tostring(name), 0)
          end
        end
      end)

      if not ok and server_error == nil then
        server_error = err
      end

      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port
            .. "/app?compressors=zlib&zlibCompressionLevel=6",
          {
            heartbeat_frequency_ms = 500,
            runtime = mongodb.runtime.copas({ compression = compression }),
            server_selection_timeout_ms = 2000,
          }
        ))
        local reply = assert(client:database():run_command("ping"))

        assert.are.equal(1, reply:get("ok"):to_number())
        assert(client:close())
      end))
      copas.removeserver(server)
    end)

    if server_error then
      error(server_error, 0)
    elseif not outcome[1] then
      error(outcome[2], 0)
    end

    assert.is_true(handshakes >= 3)
    assert.is_true(compression_offers >= 3)
    assert.are.equal(1, compressed_pings)
    assert.are.equal(1, pings)
  end)
end)
