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

local bootstrap_uri = required_environment("MONGODB_GSSAPI_BOOTSTRAP_URI")
local host = required_environment("MONGODB_GSSAPI_HOST")
local port = required_environment("MONGODB_GSSAPI_PORT")
local principal = required_environment("MONGODB_GSSAPI_PRINCIPAL")

local function encoded_component(value)
  local encoded = value:gsub("([^%w%-%._~])", function(character)
    return string.format("%%%02X", string.byte(character))
  end)

  return encoded
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
end)
