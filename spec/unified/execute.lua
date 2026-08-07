local ROOT = os.getenv("PWD") or "."

package.path = ROOT .. "/src/?.lua;" .. ROOT .. "/src/?/init.lua;" .. package.path

local bson = require("mongodb.bson")
local copas = require("copas")
local op_msg = require("mongodb.wire.op_msg")
local runtime_module = require("mongodb.runtime")
local socket = require("socket")
local unified_driver = require("mongodb.unified.driver")

local SUPPORTED_ID = "crud/tests/unified/insertOne.json::test[1]"

local function equal(expected, actual, message)
  assert(expected == actual, message or string.format(
    "expected %s, got %s",
    tostring(expected),
    tostring(actual)
  ))
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

local function selected_document(document)
  local entries = {}

  for key, value in document:iter() do
    if key == "tests" then
      entries[#entries + 1] = { key, bson.array({ value:get(1) }) }
    else
      entries[#entries + 1] = { key, value }
    end
  end

  return bson.document(entries)
end

local function run(identity)
  if identity ~= SUPPORTED_ID then
    error("no unified executor is registered for " .. tostring(identity), 0)
  end

  local path = ROOT .. "/planning/specifications/source/crud/tests/unified/insertOne.json"
  local file = assert(io.open(path, "rb"))
  local document = assert(bson.json.decode(file:read("*a")))

  file:close()

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
      local report = assert(lifecycle:run_file(selected_document(document), identity))

      if report.summary.failed > 0 then
        error(report.tests[1].error, 0)
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

local ok, err = pcall(run, arg[1])

if not ok then
  io.stderr:write("unified executor: " .. tostring(err) .. "\n")
  os.exit(1)
end
