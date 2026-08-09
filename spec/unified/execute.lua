local ROOT = os.getenv("PWD") or "."

package.path = ROOT .. "/src/?.lua;" .. ROOT .. "/src/?/init.lua;" .. package.path

local bson = require("mongodb.bson")
local client_module = require("mongodb.client")
local config_uri = require("mongodb.config.uri")
local copas = require("copas")
local op_msg = require("mongodb.wire.op_msg")
local runtime_module = require("mongodb.runtime")
local socket = require("socket")
local unified_driver = require("mongodb.unified.driver")

local INSERT_ONE_ID = "crud/tests/unified/insertOne.json::test[1]"

local function equal(expected, actual, message)
  assert(expected == actual, message or string.format(
    "expected %s, got %s",
    tostring(expected),
    tostring(actual)
  ))
end

local function report_error(err)
  if type(err) == "table" and err.details and err.details.path then
    return tostring(err) .. " at " .. tostring(err.details.path)
  end

  return err
end

local function receive_frame(peer)
  local header = assert(peer:receive(4))
  local size = string.unpack("<i4", header)

  return assert(op_msg.decode(header .. assert(peer:receive(size - 4)), {
    direction = "request",
  }))
end

local function send_response(peer, request, body)
  return assert(peer:send(assert(op_msg.encode({
    body = body,
    direction = "response",
    request_id = 5000 + request.request_id,
    response_to = request.request_id,
  }))))
end

local function command_name(request)
  return request.body:keys()[1]
end

local function request_documents(request)
  local documents = request.body:get("documents")

  if documents then
    return documents
  end

  for _, sequence in ipairs(request.sequences or {}) do
    if sequence.identifier == "documents" then
      return bson.array(sequence.documents)
    end
  end

  error("insert command has no documents", 0)
end

local function serve_connection(peer, store)
  peer = copas.wrap(peer)
  local handshake = receive_frame(peer)

  equal("ismaster", command_name(handshake))
  send_response(peer, handshake, bson.document({
    { "ok", 1 },
    { "helloOk", true },
    { "isWritablePrimary", true },
    { "maxBsonObjectSize", 16777216 },
    { "maxMessageSizeBytes", 48000000 },
    { "maxWriteBatchSize", 100000 },
    { "maxWireVersion", 25 },
  }))

  local request = receive_frame(peer)
  local name = command_name(request)

  if name == "drop" then
    local concern = request.body:get("writeConcern")

    equal("majority", concern:get("w"))
    store.documents = {}
    send_response(peer, request, bson.document({ { "ok", 1 } }))

    request = receive_frame(peer)
    equal("insert", command_name(request))
    concern = request.body:get("writeConcern")
    equal("majority", concern:get("w"))

    for _, document in request_documents(request):iter() do
      store.documents[#store.documents + 1] = document
    end

    send_response(peer, request, bson.document({ { "ok", 1 }, { "n", 1 } }))

    request = receive_frame(peer)
    equal("find", command_name(request))
    equal(1, request.body:get("sort"):get("_id"):to_number())
    send_response(peer, request, bson.document({
      { "ok", 1 },
      { "cursor", bson.document({
        { "id", bson.int64(0) },
        { "ns", "crud-v1.coll" },
        { "firstBatch", bson.array(store.documents) },
      }) },
    }))
  elseif name == "insert" then
    assert(request.body:get("writeConcern") == nil, "unexpected writeConcern")

    for _, document in request_documents(request):iter() do
      store.documents[#store.documents + 1] = document
    end

    send_response(peer, request, bson.document({ { "ok", 1 }, { "n", 1 } }))
  else
    error("unsupported loopback unified command: " .. tostring(name), 0)
  end

  peer:close()
end

local function selected_test(tests, wanted_index, run_skipped)
  local test = tests:get(wanted_index)

  if not run_skipped then
    return test
  end

  local entries = {}

  for key, value in test:iter() do
    if key ~= "skipReason" then
      entries[#entries + 1] = { key, value }
    end
  end

  return bson.document(entries)
end

local function selected_document(document, wanted_index, run_skipped)
  local entries = {}

  for key, value in document:iter() do
    if key == "tests" then
      entries[#entries + 1] = {
        key,
        bson.array({ selected_test(value, wanted_index, run_skipped) }),
      }
    else
      entries[#entries + 1] = { key, value }
    end
  end

  return bson.document(entries)
end

local function database_names(value, result)
  result = result or {}

  if bson.is_document(value) then
    local name = value:get("databaseName")

    if type(name) == "string" and name ~= "admin" and name ~= "config"
        and name ~= "local"
    then
      result[name] = true
    end

    for _, item in value:iter() do
      database_names(item, result)
    end
  elseif bson.is_array(value) then
    for _, item in value:iter() do
      database_names(item, result)
    end
  end

  return result
end

local function reset_databases(runtime, uri, document)
  local client = assert(client_module.connect(uri, { runtime = runtime }))
  local admin = assert(client:database("admin"))

  admin:run_command(bson.document({
    { "configureFailPoint", "failCommand" },
    { "mode", "off" },
  }), { monitor = false })

  for name in pairs(database_names(document)) do
    assert(client:drop_database(name))
  end

  assert(client:close())
end

local function load_json(path)
  local file = assert(io.open(path, "rb"))
  local document = assert(bson.json.decode(file:read("*a")))

  file:close()
  return document
end

local function registered_test(identity)
  local registry = load_json(ROOT .. "/spec/unified/executors.json")
  local tests = registry:get("tests")
  local entry = tests and tests:get(identity)

  if not entry then
    error("no unified executor is registered for " .. tostring(identity), 0)
  end

  local fixture, index = identity:match("^(.-)::test%[(%d+)%]$")

  if not fixture or not index then
    error("registered unified identity is malformed: " .. tostring(identity), 0)
  end

  return entry, fixture, assert(math.tointeger(tonumber(index)))
end

local function run_loopback(identity, fixture, index)
  equal(INSERT_ONE_ID, identity)
  local document = load_json(ROOT .. "/planning/specifications/source/" .. fixture)

  local server = assert(socket.bind("127.0.0.1", 0))
  local _, port = assert(server:getsockname())
  local store = { documents = {} }
  local server_error
  local outcome

  port = assert(math.tointeger(port))
  copas.addserver(server, function(peer)
    local ok, err = pcall(serve_connection, peer, store)

    if not ok then
      server_error = err
      pcall(peer.close, peer)
    end
  end)

  copas.loop(function()
    outcome = table.pack(pcall(function()
      local lifecycle = assert(unified_driver.new({
        environment = {
          server_version = "8.2.0",
          topology = "single",
        },
        runtime = runtime_module.copas(),
        uri = "mongodb://127.0.0.1:" .. port,
      }))
      local report = assert(lifecycle:run_file(selected_document(document, index), identity))

      if report.summary.failed > 0 then
        error(report_error(report.tests[1].error), 0)
      end

      equal(1, report.summary.executed)
      equal(1, report.summary.passed)
      equal(0, report.summary.failed)
      assert(lifecycle:close())
    end))
    copas.removeserver(server)
  end)

  if not outcome[1] then
    error(outcome[2], 0)
  end

  if server_error then
    error(server_error, 0)
  end

  print("unified executor: 1 executed, 1 passed, 0 failed")
end

local function run_live(identity, fixture, index, topology, entry)
  local replica_set = topology == "replicaset"
  local uri = os.getenv(replica_set
    and "MONGODB_UNIFIED_REPLICA_SET_URI" or "MONGODB_UNIFIED_URI")
  local server_version = os.getenv(replica_set
    and "MONGODB_UNIFIED_REPLICA_SET_SERVER_VERSION"
    or "MONGODB_UNIFIED_SERVER_VERSION")

  if type(uri) ~= "string" or uri == "" then
    error("live unified executor requires MONGODB_UNIFIED_URI", 0)
  end

  if type(server_version) ~= "string" or server_version == "" then
    error("live unified executor requires MONGODB_UNIFIED_SERVER_VERSION", 0)
  end

  local parsed = assert(config_uri.parse(uri))
  local document = load_json(ROOT .. "/planning/specifications/source/" .. fixture)
  local outcome

  copas.loop(function()
    outcome = table.pack(pcall(function()
      local runtime = runtime_module.copas()
      local selected = selected_document(
        document,
        index,
        entry:get("runSkipped") == true
      )

      reset_databases(runtime, uri, selected)
      local lifecycle = assert(unified_driver.new({
        environment = {
          auth = parsed.username ~= nil,
          server_parameters = bson.document({
            { "acceptApiVersion2", entry:get("acceptApiVersion2") == true },
            { "enableTestCommands", os.getenv("MONGODB_UNIFIED_TEST_COMMANDS") == "1" },
            { "requireApiVersion", false },
          }),
          server_version = server_version,
          topology = topology,
        },
        runtime = runtime,
        uri = uri,
      }))
      local executed = table.pack(pcall(function()
        local report = assert(lifecycle:run_file(
          selected,
          identity
        ))

        if report.summary.failed > 0 then
          error(report_error(report.tests[1].error), 0)
        end

        if report.summary.skipped > 0 then
          return "environment_skipped"
        end

        equal(1, report.summary.executed)
        equal(1, report.summary.passed)
        equal(0, report.summary.failed)
        equal(0, report.summary.skipped)
        return "passed"
      end))

      assert(lifecycle:close())

      if not executed[1] then
        error(executed[2], 0)
      end

      return executed[2]
    end))
  end)

  if not outcome[1] then
    error(outcome[2], 0)
  end

  if outcome[2] == "environment_skipped" then
    return "environment_skipped"
  end

  print("unified executor: 1 executed, 1 passed, 0 failed")
end

local function run(identity)
  local entry, fixture, index = registered_test(identity)
  local environment = entry:get("environment")

  if entry:get("testCommands") == true
    and os.getenv("MONGODB_UNIFIED_TEST_COMMANDS") ~= "1"
  then
    return "environment_skipped"
  end

  if environment == "deterministic-loopback" then
    return run_loopback(identity, fixture, index)
  elseif environment == "live-standalone" then
    return run_live(identity, fixture, index, "single", entry)
  elseif environment == "live-replicaset" then
    return run_live(identity, fixture, index, "replicaset", entry)
  elseif environment == "isolated-replicaset" then
    return run_live(identity, fixture, index, "replicaset", entry)
  end

  error("unknown unified executor environment: " .. tostring(environment), 0)
end

local ok, err = pcall(run, arg[1])

if not ok then
  io.stderr:write("unified executor: " .. tostring(err) .. "\n")
  os.exit(1)
end

if err == "environment_skipped" then
  io.stderr:write("unified executor: test commands are unavailable\n")
  os.exit(75)
end
