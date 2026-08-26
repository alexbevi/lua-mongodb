local function required_environment(name)
  local value = os.getenv(name)

  assert(value ~= nil and value ~= "", name .. " must be set for live GSSAPI testing")
  return value
end

if os.getenv("MONGODB_GSSAPI_LIVE") ~= "1" then
  pending("set MONGODB_GSSAPI_LIVE=1 for live GSSAPI authentication", function() end)
  return
end

local package_tree = required_environment("MONGODB_GSSAPI_PACKAGE_TREE")
local lua_version = _VERSION:match("Lua (%d+%.%d+)")

package.path = package_tree .. "/share/lua/" .. lua_version .. "/?.lua;"
  .. package_tree .. "/share/lua/" .. lua_version .. "/?/init.lua;"
  .. package.path
package.cpath = package_tree .. "/lib/lua/" .. lua_version .. "/?.so;"
  .. package.cpath

local bson = require("mongodb.bson")
local mongodb = require("mongodb")
local network_transport = require("mongodb.network.transport")
local op_msg = require("mongodb.wire.op_msg")

local bootstrap_uri = required_environment("MONGODB_GSSAPI_BOOTSTRAP_URI")
local host = required_environment("MONGODB_GSSAPI_HOST")
local port = required_environment("MONGODB_GSSAPI_PORT")
local principal = required_environment("MONGODB_GSSAPI_PRINCIPAL")
local request_id = 7000

local function encoded_component(value)
  local encoded = value:gsub("([^%w%-%._~])", function(character)
    return string.format("%%%02X", string.byte(character))
  end)

  return encoded
end

local function direct_command(runtime, command_port, database, command)
  local entries = command:entries()

  entries[#entries + 1] = { "$db", database }
  request_id = request_id + 1

  local connection = assert(network_transport.connect(
    runtime,
    "127.0.0.1",
    assert(math.tointeger(command_port))
  ))
  local request = assert(op_msg.encode({
    body = bson.document(entries),
    direction = "request",
    request_id = request_id,
  }))

  assert.is_true(connection:write_all(request))

  local response = assert(op_msg.decode(assert(connection:read_frame(48000000)), {
    direction = "response",
    expected_response_to = request_id,
  }))

  assert.is_true(connection:close())
  return response.body
end

local function wait_for_primary(runtime, replica_set_port)
  for _ = 1, 100 do
    local hello = direct_command(
      runtime,
      replica_set_port,
      "admin",
      bson.document({ { "hello", 1 } })
    )

    if hello:get("isWritablePrimary") == true then
      return true
    end

    assert(runtime.clock:sleep(0.05))
  end

  error("the live GSSAPI replica set did not elect a primary", 0)
end

describe("live GSSAPI authentication", function()
  it("uses the current ticket cache to ping a standalone", function()
    mongodb.run(function()
      local bootstrap = assert(mongodb.client(bootstrap_uri))
      local created = bootstrap:database("$external"):run_command(bson.document({
        { "createUser", principal },
        { "roles", bson.array({}) },
      }))

      assert.is_not_nil(created)
      assert.is_true(bootstrap:close())

      local uri = "mongodb://" .. encoded_component(principal)
        .. "@" .. host .. ":" .. port .. "/?authMechanism=GSSAPI"
      local client = assert(mongodb.client(uri))

      assert.is_not_nil(client:database("admin"):run_command("ping"))
      assert.is_true(client:close())
    end)
  end)

  it("uses an explicit password when the provider supports it", function()
    local password = required_environment("MONGODB_GSSAPI_PASSWORD")
    local runtime = mongodb.runtime.copas()
    local capabilities = assert(runtime.gssapi):capabilities()

    assert.is_true(capabilities.password_credentials)

    mongodb.run(function()
      local uri = "mongodb://" .. encoded_component(principal)
        .. ":" .. encoded_component(password)
        .. "@" .. host .. ":" .. port .. "/?authMechanism=GSSAPI"
      local client = assert(mongodb.client(uri, { runtime = runtime }))

      assert.is_not_nil(client:database("admin"):run_command("ping"))
      assert.is_true(client:close())
    end)
  end)

  it("canonicalizes the endpoint host with forward and reverse DNS", function()
    local endpoint = required_environment("MONGODB_GSSAPI_CANONICAL_ENDPOINT")

    mongodb.run(function()
      local uri = "mongodb://" .. encoded_component(principal)
        .. "@" .. endpoint .. ":" .. port .. "/?authMechanism=GSSAPI"
        .. "&authMechanismProperties=CANONICALIZE_HOST_NAME:forwardAndReverse"
      local client = assert(mongodb.client(uri))

      assert.is_not_nil(client:database("admin"):run_command("ping"))
      assert.is_true(client:close())
    end)
  end)

  it("uses SERVICE_HOST without replacing the selected endpoint", function()
    local endpoint = required_environment("MONGODB_GSSAPI_SERVICE_ENDPOINT")
    local runtime = mongodb.runtime.copas()
    local socket = runtime.socket

    runtime.socket = {
      connect = function(_, selected_host, ...)
        assert.are.equal(endpoint, selected_host)
        return socket:connect(selected_host, ...)
      end,
    }

    mongodb.run(function()
      local uri = "mongodb://" .. encoded_component(principal)
        .. "@" .. endpoint .. ":" .. port .. "/?authMechanism=GSSAPI"
        .. "&authMechanismProperties=SERVICE_HOST:" .. host
      local client = assert(mongodb.client(uri, { runtime = runtime }))

      assert.is_not_nil(client:database("admin"):run_command("ping"))
      assert.is_true(client:close())
    end)
  end)

  it("authenticates after replica-set discovery", function()
    local replica_set = required_environment("MONGODB_GSSAPI_REPLICA_SET")
    local replica_set_port = required_environment("MONGODB_GSSAPI_REPLICA_SET_PORT")

    mongodb.run(function()
      local runtime = mongodb.runtime.copas()
      local initiated = direct_command(
        runtime,
        replica_set_port,
        "admin",
        bson.document({
          { "replSetInitiate", bson.document({
            { "_id", replica_set },
            { "members", bson.array({
              bson.document({
                { "_id", 0 },
                { "host", host .. ":" .. replica_set_port },
              }),
            }) },
          }) },
        })
      )

      assert.are.equal(1, initiated:get("ok"):to_number())
      assert.is_true(wait_for_primary(runtime, replica_set_port))

      local created = direct_command(
        runtime,
        replica_set_port,
        "$external",
        bson.document({
          { "createUser", principal },
          { "roles", bson.array({}) },
        })
      )

      assert.are.equal(1, created:get("ok"):to_number())

      local uri = "mongodb://" .. encoded_component(principal)
        .. "@" .. host .. ":" .. replica_set_port
        .. "/?authMechanism=GSSAPI&replicaSet=" .. replica_set
      local client = assert(mongodb.client(uri, { runtime = runtime }))

      assert.is_not_nil(client:database("admin"):run_command("ping"))
      assert.is_true(client:close())
    end)
  end)

  it("uses independent contexts for concurrent application connections", function()
    local client_count = assert(math.tointeger(
      required_environment("MONGODB_GSSAPI_CONCURRENT_CLIENTS")
    ))

    assert.is_true(client_count >= 2)

    mongodb.run(function()
      local runtime = mongodb.runtime.copas()
      local native_provider = assert(runtime.gssapi)
      local native_contexts = {}
      local closed_contexts = 0

      runtime.gssapi = {
        capabilities = function()
          return native_provider:capabilities()
        end,
        create_context = function(_, options, deadline, cancellation)
          local native_context, err = native_provider:create_context(
            options,
            deadline,
            cancellation
          )

          if native_context == nil then
            return nil, err
          end

          native_contexts[#native_contexts + 1] = native_context
          local wait_deadline = runtime.clock:now() + 5

          while #native_contexts < client_count do
            if runtime.clock:now() >= wait_deadline then
              native_context:close()
              error("concurrent GSSAPI contexts did not overlap", 0)
            end

            assert(runtime.clock:sleep(0.001, cancellation))
          end

          local closed = false

          return {
            step = function(_, ...)
              return native_context:step(...)
            end,
            security_layer = function(_, ...)
              return native_context:security_layer(...)
            end,
            close = function()
              local ok, close_err = native_context:close()

              if ok and not closed then
                closed = true
                closed_contexts = closed_contexts + 1
              end

              return ok, close_err
            end,
          }
        end,
      }

      local uri = "mongodb://" .. encoded_component(principal)
        .. "@" .. host .. ":" .. port .. "/?authMechanism=GSSAPI"
      local tasks = {}

      for index = 1, client_count do
        tasks[index] = runtime.task:spawn(function()
          local client = assert(mongodb.client(uri, { runtime = runtime }))
          local reply = assert(client:database("admin"):run_command("ping"))

          assert.is_true(client:close())
          return reply:get("ok"):to_number()
        end)
      end

      for index = 1, client_count do
        assert.are.equal(1, runtime.task:await(tasks[index]))
      end

      assert.are.equal(client_count, #native_contexts)
      assert.are.equal(client_count, closed_contexts)

      for index = 2, client_count do
        assert.are_not.equal(native_contexts[1], native_contexts[index])
      end
    end)
  end)
end)
