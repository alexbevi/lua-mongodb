local copas = require("copas")
local errors = require("mongodb.error")
local runtime = require("mongodb.runtime")
local socket = require("socket")
local ssl = require("ssl")
local transport = require("mongodb.network.transport")

local TLS_DIR = "spec/fixtures/tls/"

local function server_context(require_client_certificate)
  local parameters = {
    certificate = TLS_DIR .. "server.pem",
    key = TLS_DIR .. "server-key.pem",
    mode = "server",
    options = { "all", "no_sslv2", "no_sslv3", "no_compression" },
    protocol = "any",
    verify = "none",
  }

  if require_client_certificate then
    parameters.cafile = TLS_DIR .. "ca.pem"
    parameters.verify = { "peer", "fail_if_no_peer_cert" }
  end

  return assert(ssl.newcontext(parameters))
end

local function add_tls_server(context, handler)
  local server = assert(socket.bind("127.0.0.1", 0))
  local _, port = assert(server:getsockname())
  port = assert(math.tointeger(port))

  copas.addserver(server, function(client)
    local wrapped = copas.wrap(client)
    local ok = pcall(function()
      assert(wrapped:dohandshake(context))
      handler(wrapped)
    end)

    if not ok then
      wrapped:close()
    end
  end)

  return server, port
end

local function run_client(server, callback)
  local outcome

  copas.loop(function()
    outcome = table.pack(pcall(callback))
    copas.removeserver(server)
  end)

  assert.is_table(outcome)

  if not outcome[1] then
    error(outcome[2], 0)
  end

  return table.unpack(outcome, 2, outcome.n)
end

local function verified_options(extra)
  local options = {
    ca_file = TLS_DIR .. "ca.pem",
    certificate_key_file = TLS_DIR .. "client.pem",
    certificate_key_file_password = "test-client-password",
    server_name = "localhost",
  }

  for key, value in pairs(extra or {}) do
    options[key] = value
  end

  return options
end

describe("Copas LuaSec TLS transport", function()
  it("validates CA, hostname, and client certificate before I/O", function()
    local server, port = add_tls_server(server_context(true), function(client)
      assert.are.equal("hello", assert(client:receive(5)))
      assert(client:send("world"))
      client:close()
    end)

    run_client(server, function()
      local adapter = runtime.copas()
      local deadline = runtime.deadline_after(adapter, 2)
      local connection = assert(transport.connect(adapter, "127.0.0.1", port, {
        deadline = deadline,
        tls = verified_options(),
      }))

      assert.is_true(connection:write_all("hello", deadline))
      assert.are.equal("world", assert(connection:read_exact(5, deadline)))
      assert.is_true(connection:close())
    end)
  end)

  it("rejects hostname and CA mismatches with redacted errors", function()
    local server, port = add_tls_server(server_context(false), function(client)
      client:close()
    end)

    run_client(server, function()
      local adapter = runtime.copas()
      local value, err = transport.connect(adapter, "127.0.0.1", port, {
        deadline = runtime.deadline_after(adapter, 2),
        tls = verified_options({ server_name = "wrong.invalid" }),
      })

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
      assert.are.equal("TLS certificate does not match the server name", err.message)
      assert.is_nil(tostring(err):find("wrong.invalid", 1, true))
    end)

    server, port = add_tls_server(server_context(false), function(client)
      client:close()
    end)

    run_client(server, function()
      local adapter = runtime.copas()
      local value, err = transport.connect(adapter, "127.0.0.1", port, {
        deadline = runtime.deadline_after(adapter, 2),
        tls = verified_options({ ca_file = TLS_DIR .. "wrong-ca.pem" }),
      })

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
      assert.are.equal("TLS handshake failed", err.message)
      assert.is_nil(tostring(err):find("wrong-ca.pem", 1, true))
    end)
  end)

  it("matches DNS wildcards and IP subject alternatives", function()
    for _, server_name in ipairs({ "db.example.test", "127.0.0.1" }) do
      local server, port = add_tls_server(server_context(false), function(client)
        assert.are.equal("x", assert(client:receive(1)))
        assert(client:send("y"))
        client:close()
      end)

      run_client(server, function()
        local adapter = runtime.copas()
        local deadline = runtime.deadline_after(adapter, 2)
        local connection = assert(transport.connect(adapter, "127.0.0.1", port, {
          deadline = deadline,
          tls = verified_options({ server_name = server_name }),
        }))

        assert.is_true(connection:write_all("x", deadline))
        assert.are.equal("y", assert(connection:read_exact(1, deadline)))
        connection:close()
      end)
    end
  end)

  it("applies insecure policy explicitly", function()
    local server, port = add_tls_server(server_context(false), function(client)
      assert.are.equal("x", assert(client:receive(1)))
      assert(client:send("y"))
      client:close()
    end)

    run_client(server, function()
      local adapter = runtime.copas()
      local deadline = runtime.deadline_after(adapter, 2)
      local connection = assert(transport.connect(adapter, "127.0.0.1", port, {
        deadline = deadline,
        tls = {
          insecure = true,
          server_name = "wrong.invalid",
        },
      }))

      assert.is_true(connection:write_all("x", deadline))
      assert.are.equal("y", assert(connection:read_exact(1, deadline)))
      connection:close()
    end)
  end)

  it("applies deadlines and cancellation during the handshake", function()
    local function stalled_server()
      local server = assert(socket.bind("127.0.0.1", 0))
      local _, port = assert(server:getsockname())

      copas.addserver(server, function(client)
        copas.pause(0.1)
        client:close()
      end)
      return server, assert(math.tointeger(port))
    end

    local server, port = stalled_server()

    run_client(server, function()
      local adapter = runtime.copas({ lock_poll_interval = 0.001 })
      local value, err = transport.connect(adapter, "127.0.0.1", port, {
        deadline = runtime.deadline_after(adapter, 0.005),
        tls = verified_options(),
      })

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))
    end)

    server, port = stalled_server()

    run_client(server, function()
      local adapter = runtime.copas({ lock_poll_interval = 0.001 })
      local token = adapter.cancellation:new()

      adapter.task:spawn(function()
        adapter.clock:sleep(0.005)
        token:cancel("stop TLS")
      end)

      local value, err = transport.connect(adapter, "127.0.0.1", port, {
        cancellation = token,
        deadline = runtime.deadline_after(adapter, 1),
        tls = verified_options(),
      })

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))
      assert.are.equal("stop TLS", err.message)
    end)
  end)
end)
