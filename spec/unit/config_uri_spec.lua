local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local uri = require("mongodb.config.uri")

local FIXTURE_ROOT = (os.getenv("PWD") or ".")
  .. "/planning/specifications/source/connection-string/tests/"

local function read_fixture(name)
  local file = assert(io.open(FIXTURE_ROOT .. name, "rb"))
  local content = file:read("*a")

  file:close()
  return assert(bson.json.decode(content))
end

local function expected_hosts(test)
  local hosts = {}

  for index, expected in test:get("hosts"):iter() do
    local host = {
      host = expected:get("host"),
      type = expected:get("type"),
    }
    local port = expected:get("port")

    if not bson.is_null(port) then
      host.port = port.value or port
    end

    hosts[index] = host
  end

  return hosts
end

describe("MongoDB connection string parser", function()
  it("parses escaped credentials, IPv6 seeds, database, and ordered options", function()
    local parsed = assert(uri.parse(
      "mongodb://alice:p%40ss@example.com,[::1]:27018/admin?replicaSet=rs0&tls=true"
    ))

    assert.are.equal("alice", parsed.username)
    assert.are.equal("p@ss", parsed.password)
    assert.are.equal("admin", parsed.database)
    assert.are.same({
      { host = "example.com", type = "hostname" },
      { host = "::1", port = 27018, type = "ip_literal" },
    }, parsed.hosts)
    assert.are.same({
      { key = "replicaset", value = "rs0" },
      { key = "tls", value = "true" },
    }, parsed.options)
  end)

  it("never includes credentials in parse errors", function()
    local parsed, err = uri.parse("mongodb://alice:top-secret@localhost:bad/admin")

    assert.is_nil(parsed)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.is_nil(tostring(err):find("top-secret", 1, true))
  end)

  it("runs every pinned non-SRV connection-string fixture at the syntax layer", function()
    local fixtures = {
      "invalid-uris.json",
      "valid-auth.json",
      "valid-db-with-dotted-name.json",
      "valid-host_identifiers.json",
      "valid-options.json",
      "valid-unix_socket-absolute.json",
      "valid-unix_socket-relative.json",
      "valid-warnings.json",
    }
    local count = 0

    for _, fixture_name in ipairs(fixtures) do
      local fixture = read_fixture(fixture_name)

      for _, test in fixture:get("tests"):iter() do
        local description = fixture_name .. ": " .. test:get("description")
        local parsed, err = uri.parse(test:get("uri"))

        if test:get("valid") then
          assert.is_nil(err, description)
          assert.are.same(expected_hosts(test), parsed.hosts, description)

          local auth = test:get("auth")

          if not bson.is_null(auth) then
            local username = auth:get("username")

            if bson.is_null(username) then
              assert.is_nil(parsed.username, description)
            else
              assert.are.equal(username, parsed.username, description)
            end

            local password = auth:get("password")

            if bson.is_null(password) then
              assert.is_nil(parsed.password, description)
            else
              assert.are.equal(password, parsed.password, description)
            end

            local database = auth:get("db")

            if not bson.is_null(database) then
              assert.are.equal(database, parsed.database, description)
            end
          end

          if description:find("Repeated option keys", 1, true) then
            assert.are.equal(1, #parsed.warnings, description)
          end
        else
          assert.is_nil(parsed, description)
          assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION), description)
        end

        count = count + 1
      end
    end

    assert.are.equal(98, count)
  end)
end)
