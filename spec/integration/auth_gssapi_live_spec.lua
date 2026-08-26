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

local function encoded_username(username)
  return username:gsub("([^%w%-%._~])", function(character)
    return string.format("%%%02X", string.byte(character))
  end)
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

      local uri = "mongodb://" .. encoded_username(principal)
        .. "@" .. host .. ":" .. port .. "/?authMechanism=GSSAPI"
      local client = assert(mongodb.client(uri))

      assert.is_not_nil(client:database("admin"):run_command("ping"))
      assert.is_true(client:close())
    end)
  end)
end)
