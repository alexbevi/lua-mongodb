local ROOT = os.getenv("PWD") or "."

package.path = ROOT .. "/src/?.lua;" .. ROOT .. "/src/?/init.lua;" .. package.path

local bson = require("mongodb.bson")
local client_module = require("mongodb.client")
local config_uri = require("mongodb.config.uri")
local copas = require("copas")
local errors = require("mongodb.error")
local op_msg = require("mongodb.wire.op_msg")
local runtime_module = require("mongodb.runtime")
local socket = require("socket")
local unified_driver = require("mongodb.unified.driver")

local INSERT_ONE_ID = "crud/tests/unified/insertOne.json::test[1]"
local OIDC_READ_ID = "auth/tests/unified/mongodb-oidc-no-retry.json::test[1]"
local OIDC_WRITE_ID = "auth/tests/unified/mongodb-oidc-no-retry.json::test[2]"
local OIDC_SPECULATIVE_CACHED_ID =
  "auth/tests/unified/mongodb-oidc-no-retry.json::test[5]"
local OIDC_SPECULATIVE_UNCACHED_ID =
  "auth/tests/unified/mongodb-oidc-no-retry.json::test[6]"
local OIDC_IDS = {
  [OIDC_READ_ID] = true,
  [OIDC_SPECULATIVE_CACHED_ID] = true,
  [OIDC_SPECULATIVE_UNCACHED_ID] = true,
  [OIDC_WRITE_ID] = true,
}

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

local function receive_frame_or_closed(peer)
  local header, err = peer:receive(4)

  if header == nil and err == "closed" then
    return nil
  end

  assert(header, err)
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

local function serve_oidc_connection(peer, store)
  peer = copas.wrap(peer)
  local handshake = assert(receive_frame_or_closed(peer))

  equal("ismaster", command_name(handshake))
  local hello_entries = {
    { "ok", 1 },
    { "helloOk", true },
    { "isWritablePrimary", true },
    { "maxBsonObjectSize", 16777216 },
    { "maxMessageSizeBytes", 48000000 },
    { "maxWriteBatchSize", 100000 },
    { "maxWireVersion", 25 },
  }
  local speculative = handshake.body:get("speculativeAuthenticate")

  if bson.is_document(speculative) then
    equal("MONGODB-OIDC", speculative:get("mechanism"))
    local payload = assert(bson.decode(speculative:get("payload").data))

    equal("loopback-oidc-token", payload:get("jwt"))
    hello_entries[#hello_entries + 1] = {
      "speculativeAuthenticate",
      bson.document({
        { "conversationId", 1 },
        { "payload", bson.binary("") },
        { "done", true },
        { "ok", 1 },
      }),
    }
  end

  send_response(peer, handshake, bson.document(hello_entries))

  while true do
    local request = receive_frame_or_closed(peer)

    if request == nil then
      return
    end

    local name = command_name(request)

    if name == "saslStart" then
      equal("MONGODB-OIDC", request.body:get("mechanism"))
      local payload = assert(bson.decode(request.body:get("payload").data))

      equal("loopback-oidc-token", payload:get("jwt"))
      if (store.fail_sasl_start or 0) > 0 then
        store.fail_sasl_start = store.fail_sasl_start - 1
        send_response(peer, request, bson.document({
          { "ok", 0 },
          { "code", 18 },
          { "errmsg", "OIDC authentication failed" },
        }))
      else
        send_response(peer, request, bson.document({
          { "conversationId", 1 },
          { "payload", bson.binary("") },
          { "done", true },
          { "ok", 1 },
        }))
      end
    elseif name == "configureFailPoint" then
      local mode = request.body:get("mode")

      if mode == "off" then
        store.close_insert = 0
        store.fail_sasl_start = 0
      else
        local data = assert(request.body:get("data"))
        local commands = assert(data:get("failCommands"))

        for _, command in commands:iter() do
          if command == "insert" and data:get("closeConnection") == true then
            store.close_insert = 1
          elseif command == "saslStart" then
            equal(18, data:get("errorCode"):to_number())
            store.fail_sasl_start = 1
          end
        end
      end

      send_response(peer, request, bson.document({ { "ok", 1 } }))
    elseif name == "drop" then
      store.documents = {}
      send_response(peer, request, bson.document({ { "ok", 1 }, { "n", 1 } }))
    elseif name == "create" then
      send_response(peer, request, bson.document({ { "ok", 1 } }))
    elseif name == "find" then
      send_response(peer, request, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "test.collName" },
          { "firstBatch", bson.array(store.documents) },
        }) },
      }))
    elseif name == "insert" then
      if (store.close_insert or 0) > 0 then
        store.close_insert = store.close_insert - 1
        peer:close()
        return
      end

      for _, document in request_documents(request):iter() do
        store.documents[#store.documents + 1] = document
      end

      send_response(peer, request, bson.document({ { "ok", 1 }, { "n", 1 } }))
    else
      error("unsupported OIDC loopback command: " .. tostring(name), 0)
    end
  end
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

local function selected_document(document, selections)
  local entries = {}

  for key, value in document:iter() do
    if key == "tests" then
      local tests = {}

      for index, selection in ipairs(selections) do
        tests[index] = selected_test(
          value,
          selection.index,
          selection.entry:get("runSkipped") == true
        )
      end

      entries[#entries + 1] = {
        key,
        bson.array(tests),
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

local function registered_test(registry, identity)
  local tests = registry:get("tests")
  local entry = tests and tests:get(identity)

  if not entry then
    error("no unified executor is registered for " .. tostring(identity), 0)
  end

  local fixture, index = identity:match("^(.-)::test%[(%d+)%]$")

  if not fixture or not index then
    error("registered unified identity is malformed: " .. tostring(identity), 0)
  end

  return {
    entry = entry,
    fixture = fixture,
    identity = identity,
    index = assert(math.tointeger(tonumber(index))),
  }
end

local function run_loopback(selection)
  equal(INSERT_ONE_ID, selection.identity)
  local document = load_json(
    ROOT .. "/planning/specifications/source/" .. selection.fixture
  )

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
      local report = assert(lifecycle:run_file(
        selected_document(document, { selection }),
        selection.identity
      ))

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

  return {
    {
      id = selection.identity,
      status = "passed",
    },
  }
end

local function run_oidc_loopback(selections)
  local fixture = selections[1].fixture
  local document = load_json(
    ROOT .. "/planning/specifications/source/" .. fixture
  )
  local server = assert(socket.bind("127.0.0.1", 0))
  local _, port = assert(server:getsockname())
  local store = { documents = {} }
  local server_error
  local outcome

  port = assert(math.tointeger(port))
  copas.addserver(server, function(peer)
    local ok, err = pcall(serve_oidc_connection, peer, store)

    if not ok then
      server_error = err
      pcall(peer.close, peer)
    end
  end)

  copas.loop(function()
    outcome = table.pack(pcall(function()
      local runtime = runtime_module.copas()
      local uri = "mongodb://127.0.0.1:" .. port

      for _, selection in ipairs(selections) do
        if selection.identity == OIDC_SPECULATIVE_UNCACHED_ID then
          store.fail_sasl_start = 1
          local client, err = client_module.connect(
            uri .. "/?authMechanism=MONGODB-OIDC",
            {
              app_name = "mongodb-oidc-no-retry",
              auth_mechanism_properties = {
                OIDC_CALLBACK = function()
                  return { access_token = "loopback-oidc-token" }
                end,
              },
              runtime = runtime,
            }
          )

          assert(client == nil, "uncached OIDC authentication unexpectedly succeeded")
          assert(errors.is(err, errors.CATEGORY.AUTHENTICATION))
          equal(18, err.code)
        else
          local lifecycle = assert(unified_driver.new({
            environment = {
              auth = true,
              auth_mechanism = "MONGODB-OIDC",
              server_version = "8.2.0",
              topology = "single",
            },
            oidc_callback = function()
              return { access_token = "loopback-oidc-token" }
            end,
            runtime = runtime,
            uri = uri,
          }))
          local report = assert(lifecycle:run_file(
            selected_document(document, { selection }),
            selection.identity
          ))

          if report.summary.failed > 0 then
            error(report_error(report.tests[1].error), 0)
          end

          equal(1, report.summary.executed)
          equal(1, report.summary.passed)
          equal(0, report.summary.failed)
          assert(lifecycle:close())
        end
      end
    end))
    copas.removeserver(server)
  end)

  if server_error then
    error(server_error, 0)
  end

  if not outcome[1] then
    error(outcome[2], 0)
  end

  local results = {}

  for index, selection in ipairs(selections) do
    results[index] = { id = selection.identity, status = "passed" }
  end

  return results
end

local function run_live(selections, topology)
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
  local fixture = selections[1].fixture
  local document = load_json(ROOT .. "/planning/specifications/source/" .. fixture)
  local outcome

  copas.loop(function()
    outcome = table.pack(pcall(function()
      local runtime = runtime_module.copas()
      local active = {}
      local results = {}
      local accepts_api_version_2 = false

      for _, selection in ipairs(selections) do
        local entry = selection.entry

        if entry:get("testCommands") == true
            and os.getenv("MONGODB_UNIFIED_TEST_COMMANDS") ~= "1" then
          results[selection.identity] = {
            error = "test commands are unavailable",
            id = selection.identity,
            status = "environment_skipped",
          }
        else
          active[#active + 1] = selection
          accepts_api_version_2 = accepts_api_version_2
            or entry:get("acceptApiVersion2") == true
        end
      end

      if #active == 0 then
        return results
      end

      local selected = selected_document(document, active)

      reset_databases(runtime, uri, selected)
      local lifecycle = assert(unified_driver.new({
        environment = {
          auth = parsed.username ~= nil,
          server_parameters = bson.document({
            { "acceptApiVersion2", accepts_api_version_2 },
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
          fixture
        ))

        equal(#active, report.summary.selected)

        for index, selection in ipairs(active) do
          local item = report.tests[index]
          local result = {
            id = selection.identity,
            status = item.status == "skipped"
              and "environment_skipped" or item.status,
          }

          if item.status == "failed" then
            result.error = tostring(report_error(item.error))
          elseif item.status == "skipped" then
            result.error = tostring(item.reason or "test requirements are unavailable")
          end

          results[selection.identity] = result
        end

        return results
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

  local ordered = {}

  for index, selection in ipairs(selections) do
    ordered[index] = assert(
      outcome[2][selection.identity],
      "unified batch omitted " .. selection.identity
    )
  end

  return ordered
end

local function run(identities)
  if #identities == 0 then
    error("unified executor requires at least one test identity", 0)
  end

  local registry = load_json(ROOT .. "/spec/unified/executors.json")
  local selections = {}

  for index, identity in ipairs(identities) do
    selections[index] = registered_test(registry, identity)
  end

  local fixture = selections[1].fixture
  local environment = selections[1].entry:get("environment")

  for _, selection in ipairs(selections) do
    local selected_environment = selection.entry:get("environment")

    if selection.fixture ~= fixture then
      error("unified executor batch must select exactly one fixture", 0)
    end

    if selected_environment ~= environment then
      error("unified executor batch must select exactly one environment", 0)
    end
  end

  if environment == "deterministic-loopback" then
    if OIDC_IDS[selections[1].identity] then
      for _, selection in ipairs(selections) do
        assert(OIDC_IDS[selection.identity], "mixed OIDC loopback selection")
      end

      return run_oidc_loopback(selections)
    end

    equal(1, #selections, "loopback executor only supports its exact test")
    return run_loopback(selections[1])
  elseif environment == "live-standalone" then
    return run_live(selections, "single")
  elseif environment == "live-replicaset" then
    return run_live(selections, "replicaset")
  elseif environment == "isolated-replicaset" then
    return run_live(selections, "replicaset")
  end

  error("unknown unified executor environment: " .. tostring(environment), 0)
end

local ok, results = pcall(run, arg)

if not ok then
  io.stderr:write("unified executor: " .. tostring(results) .. "\n")
  os.exit(1)
end

local encoded = {}

for index, result in ipairs(results) do
  local entries = {
    { "id", result.id },
    { "status", result.status },
  }

  if result.error ~= nil then
    entries[#entries + 1] = { "error", result.error }
  end

  encoded[index] = bson.document(entries)
end

io.write(assert(bson.json.encode(bson.document({
  { "results", bson.array(encoded) },
}))))
io.write("\n")
