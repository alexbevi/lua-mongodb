local bson = require("mongodb.bson")
local dns_discovery = require("mongodb.discovery.dns")
local fake_runtime = require("mongodb.runtime.fake")
local luassert = require("luassert")
local uri = require("mongodb.config.uri")

local M = {}

local ROOT = os.getenv("PWD") or "."
local SOURCE_ROOT = ROOT
  .. "/planning/specifications/source/initial-dns-seedlist-discovery/tests/"
local LOAD_BALANCED_SOURCE = SOURCE_ROOT .. "load-balanced/"
local REPLICA_SET_SOURCE = SOURCE_ROOT .. "replica-set/"
local SHARDED_SOURCE = SOURCE_ROOT .. "sharded/"

local LOAD_BALANCED_FIXTURES = {
  "loadBalanced-directConnection.json",
  "loadBalanced-no-results.json",
  "loadBalanced-replicaSet-errors.json",
  "loadBalanced-true-multiple-hosts.json",
  "loadBalanced-true-txt.json",
  "srvMaxHosts-conflicts_with_loadBalanced-true-txt.json",
  "srvMaxHosts-conflicts_with_loadBalanced-true.json",
  "srvMaxHosts-zero-txt.json",
  "srvMaxHosts-zero.json",
}

local FIXTURES = {
  "dbname-with-commas-escaped.json",
  "dbname-with-commas.json",
  "direct-connection-false.json",
  "direct-connection-true.json",
  "encoded-userinfo-and-db.json",
  "loadBalanced-false-txt.json",
  "longer-parent-in-return.json",
  "misformatted-option.json",
  "no-results.json",
  "not-enough-parts.json",
  "one-result-default-port.json",
  "one-txt-record-multiple-strings.json",
  "one-txt-record.json",
  "parent-part-mismatch1.json",
  "parent-part-mismatch2.json",
  "parent-part-mismatch3.json",
  "parent-part-mismatch4.json",
  "parent-part-mismatch5.json",
  "returned-parent-too-short.json",
  "returned-parent-wrong.json",
  "srv-service-name.json",
  "srvMaxHosts-conflicts_with_replicaSet-txt.json",
  "srvMaxHosts-conflicts_with_replicaSet.json",
  "srvMaxHosts-equal_to_srv_records.json",
  "srvMaxHosts-greater_than_srv_records.json",
  "srvMaxHosts-less_than_srv_records.json",
  "srvMaxHosts-zero-txt.json",
  "srvMaxHosts-zero.json",
  "two-results-default-port.json",
  "two-results-nonstandard-port.json",
  "two-txt-records.json",
  "txt-record-not-allowed-option.json",
  "txt-record-with-overridden-ssl-option.json",
  "txt-record-with-overridden-uri-option.json",
  "txt-record-with-unallowed-option.json",
  "uri-with-admin-database.json",
  "uri-with-auth.json",
  "uri-with-port.json",
  "uri-with-two-hosts.json",
  "uri-with-uppercase-hostname.json",
}
local SHARDED_FIXTURES = {
  "srvMaxHosts-equal_to_srv_records.json",
  "srvMaxHosts-greater_than_srv_records.json",
  "srvMaxHosts-less_than_srv_records.json",
  "srvMaxHosts-zero.json",
}

local OPTION_NAMES = {
  authSource = "auth_source",
  directConnection = "direct_connection",
  loadBalanced = "load_balanced",
  replicaSet = "replica_set",
  srvMaxHosts = "srv_max_hosts",
  srvServiceName = "srv_service_name",
  ssl = "tls",
}

local function srv(target, port)
  return {
    port = port or 27017,
    priority = 0,
    target = target,
    ttl = 86400,
    weight = 0,
  }
end

local DNS = {
  test1 = {
    srv("localhost.test.build.10gen.cc", 27017),
    srv("localhost.test.build.10gen.cc", 27018),
  },
  test2 = {
    srv("localhost.test.build.10gen.cc", 27018),
    srv("localhost.test.build.10gen.cc", 27019),
  },
  test3 = { srv("localhost.test.build.10gen.cc") },
  test4 = {},
  test5 = { srv("localhost.test.build.10gen.cc") },
  test6 = { srv("localhost.test.build.10gen.cc") },
  test7 = { srv("localhost.test.build.10gen.cc") },
  test8 = { srv("localhost.test.build.10gen.cc") },
  test10 = { srv("localhost.test.build.10gen.cc") },
  test11 = { srv("localhost.test.build.10gen.cc") },
  test12 = { srv("localhost.build.10gen.cc") },
  test13 = { srv("test.build.10gen.cc") },
  test14 = { srv("localhost.not-test.build.10gen.cc") },
  test15 = { srv("localhost.test.not-build.10gen.cc") },
  test16 = { srv("localhost.test.build.not-10gen.cc") },
  test17 = { srv("localhost.test.build.10gen.not-cc") },
  test18 = { srv("localhost.sub.test.build.10gen.cc") },
  test19 = {
    srv("localhost.evil.build.10gen.cc"),
    srv("localhost.test.build.10gen.cc"),
  },
  test21 = { srv("localhost.test.build.10gen.cc") },
  test22 = {
    srv("localhost.test.build.10gen.cc", 27017),
    srv("localhost.test.build.10gen.cc", 27018),
  },
  test23 = { srv("localhost.test.build.10gen.cc", 8000) },
  test24 = { srv("localhost.test.build.10gen.cc", 8000) },
}

local TXT = {
  test5 = {
    { strings = { "replicaSet=repl0&authSource=thisDB" }, ttl = 86400 },
  },
  test6 = {
    { strings = { "replicaSet=repl0" }, ttl = 86400 },
    { strings = { "authSource=otherDB" }, ttl = 86400 },
  },
  test7 = { { strings = { "ssl=false" }, ttl = 86400 } },
  test8 = { { strings = { "authSource" }, ttl = 86400 } },
  test10 = { { strings = { "socketTimeoutMS=500" }, ttl = 86400 } },
  test11 = {
    { strings = { "replicaS", "et=rep", "l0" }, ttl = 86400 },
  },
  test21 = { { strings = { "loadBalanced=false" }, ttl = 86400 } },
  test24 = { { strings = { "loadBalanced=true" }, ttl = 86400 } },
}

local function load_fixture(source, name)
  local file = assert(io.open(source .. name, "rb"))
  local fixture = assert(bson.json.decode(file:read("*a")))

  file:close()
  return fixture
end

local function plain(value)
  if bson.is_exact(value) then
    return value:to_number()
  end

  return value
end

local function queue_dns(runtime, parsed)
  local hostname = parsed.hosts[1].host
  local key = hostname:match("^([^.]+)")

  runtime:queue_dns("srv", DNS[key] or {})
  runtime:queue_dns("txt", TXT[key] or {})
end

local function address(host)
  return host.host .. ":" .. tostring(host.port)
end

local function sorted_seeds(hosts)
  local result = {}

  for index, host in ipairs(hosts) do
    result[index] = address(host)
  end

  table.sort(result)
  return result
end

local function expected_seeds(fixture)
  local result = {}
  local seeds = fixture:get("seeds")

  if not bson.is_array(seeds) then
    return nil
  end

  for index, seed in seeds:iter() do
    result[index] = seed
  end

  table.sort(result)
  return result
end

local function assert_options(fixture, config, description)
  local expected = fixture:get("options")

  if not bson.is_document(expected) then
    return
  end

  for name, value in expected:iter() do
    local option = assert(OPTION_NAMES[name], "unmapped DNS option: " .. name)

    luassert.equal(plain(value), config[option], description .. ": " .. name)
  end
end

local function parsed_value(parsed, config, name)
  if name == "user" then
    return parsed.username
  end

  if name == "password" then
    return parsed.password
  end

  if name == "db" or name == "defaultDatabase" then
    return parsed.database
  end

  if name == "auth_database" then
    return config.auth_source or parsed.database
  end

  error("unmapped parsed DNS option: " .. name, 2)
end

local function assert_parsed_options(fixture, parsed, config, description)
  local expected = fixture:get("parsed_options")

  if not bson.is_document(expected) then
    return
  end

  for name, value in expected:iter() do
    luassert.equal(
      plain(value),
      parsed_value(parsed, config, name),
      description .. ": " .. name
    )
  end
end

local function run_fixture(source, name)
  local description = "initial DNS seedlist fixture " .. name
  local fixture = load_fixture(source, name)
  local parsed, err = uri.parse(fixture:get("uri"))
  local runtime = fake_runtime.new()

  if parsed ~= nil then
    queue_dns(runtime, parsed)
    local config

    parsed, config = dns_discovery.resolve(parsed, {}, runtime, {
      random = function(maximum) return maximum end,
    })
    err = config

    if parsed ~= nil then
      err = nil
      local seeds = expected_seeds(fixture)

      if seeds ~= nil then
        luassert.same(seeds, sorted_seeds(parsed.hosts), description .. ": seeds")
      end

      local seed_count = fixture:get("numSeeds")

      if seed_count ~= nil and not bson.is_null(seed_count) then
        luassert.equal(plain(seed_count), #parsed.hosts, description .. ": seed count")
      end

      assert_options(fixture, config, description)
      assert_parsed_options(fixture, parsed, config, description)
    end
  end

  local expects_error = fixture:get("error") == true

  luassert.equal(expects_error, parsed == nil, description .. ": error result")
  luassert.equal(expects_error, err ~= nil, description .. ": structured error")
  luassert.same({}, runtime.calls.connect, description .. ": socket calls")
end

function M.run_replica_set_fixtures()
  for _, name in ipairs(FIXTURES) do
    run_fixture(REPLICA_SET_SOURCE, name)
  end

  return #FIXTURES
end

function M.run_load_balanced_fixtures()
  for _, name in ipairs(LOAD_BALANCED_FIXTURES) do
    run_fixture(LOAD_BALANCED_SOURCE, name)
  end

  return #LOAD_BALANCED_FIXTURES
end

function M.run_sharded_fixtures()
  for _, name in ipairs(SHARDED_FIXTURES) do
    run_fixture(SHARDED_SOURCE, name)
  end

  return #SHARDED_FIXTURES
end

return M
