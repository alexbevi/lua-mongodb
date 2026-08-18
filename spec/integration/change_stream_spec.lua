local bson = require("mongodb.bson")
local copas = require("copas")
local mongodb = require("mongodb")
local op_msg = require("mongodb.wire.op_msg")
local socket = require("socket")

local function receive_frame(client)
  local header = assert(client:receive(4))
  local size = string.unpack("<i4", header)
  return assert(op_msg.decode(header .. assert(client:receive(size - 4)), {
    direction = "request",
  }))
end

local function send_response(client, request, body)
  assert(client:send(assert(op_msg.encode({
    body = body,
    direction = "response",
    request_id = 2600 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("collection change streams over OP_MSG", function()
  it("opens an initial stream batch and kills the cursor on close", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local empty_token = bson.document({ { "token", "empty" } })
    local post_batch_token = bson.document({ { "token", "post-batch" } })
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local aggregate = receive_frame(peer)
      local pipeline = aggregate.body:get("pipeline")

      assert.are.equal("aggregate", aggregate.body:keys()[1])
      assert.are.equal("events", aggregate.body:get("aggregate"))
      assert.are.equal("$changeStream", pipeline:get(1):keys()[1])
      assert.are.equal(
        "futureServerMode",
        pipeline:get(1):get("$changeStream"):get("fullDocument")
      )
      assert.are.equal("$match", pipeline:get(2):keys()[1])
      assert.are.equal(
        2,
        aggregate.body:get("cursor"):get("batchSize"):to_number()
      )
      assert.are.equal("en", aggregate.body:get("collation"):get("locale"))
      assert.are.equal(
        1,
        aggregate.body:get("comment"):get("trace"):to_number()
      )
      assert.are.equal(
        "majority",
        aggregate.body:get("readConcern"):get("level")
      )
      send_response(peer, aggregate, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(51) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({}) },
        }) },
      }))

      local get_more = receive_frame(peer)

      assert.are.equal("getMore", get_more.body:keys()[1])
      assert.are.equal(2, get_more.body:get("batchSize"):to_number())
      assert.are.equal(250, get_more.body:get("maxTimeMS"):to_number())
      assert.are.equal(1, get_more.body:get("comment"):get("trace"):to_number())
      send_response(peer, get_more, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(51) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({}) },
          { "postBatchResumeToken", empty_token },
        }) },
      }))

      local blocking_get_more = receive_frame(peer)

      assert.are.equal("getMore", blocking_get_more.body:keys()[1])
      assert.are.equal(2, blocking_get_more.body:get("batchSize"):to_number())
      send_response(peer, blocking_get_more, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(51) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({
            bson.document({
              { "_id", bson.document({ { "token", 1 } }) },
              { "operationType", "insert" },
            }),
          }) },
          { "postBatchResumeToken", post_batch_token },
        }) },
      }))

      local kill = receive_frame(peer)

      assert.are.equal("killCursors", kill.body:keys()[1])
      assert.are.equal(51, kill.body:get("cursors"):get(1):to_number())
      send_response(peer, kill, bson.document({ { "ok", 1 } }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          {
            read_concern = { level = "majority" },
            runtime = mongodb.runtime.copas(),
          }
        ))
        local collection = assert(client:database():collection("events"))
        local stream = assert(collection:watch(bson.array({
          bson.document({ { "$match", bson.document({
            { "operationType", "insert" },
          }) } }),
        }), {
          batch_size = 2,
          collation = bson.document({ { "locale", "en" } }),
          comment = bson.document({ { "trace", 1 } }),
          full_document = "futureServerMode",
          max_await_time_ms = 250,
        }))

        assert.is_nil(stream:try_next())
        assert.is_false(stream:is_closed())
        assert.are.equal("empty", stream:resume_token():get("token"))
        assert.are.equal("insert", assert(stream:next()):get("operationType"))
        assert.are.equal("post-batch", stream:resume_token():get("token"))
        assert.is_true(stream:close())
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("resumes from the initial aggregate operation time", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local operation_time = bson.timestamp(70, 4)
    local event = bson.document({
      { "_id", bson.document({ { "token", "resumed" } }) },
      { "operationType", "insert" },
    })
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local aggregate = receive_frame(peer)
      local initial_stage =
        aggregate.body:get("pipeline"):get(1):get("$changeStream")

      assert.are.equal(0, #initial_stage)
      send_response(peer, aggregate, bson.document({
        { "ok", 1 },
        { "operationTime", operation_time },
        { "cursor", bson.document({
          { "id", bson.int64(52) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({}) },
        }) },
      }))

      local get_more = receive_frame(peer)

      assert.are.equal("getMore", get_more.body:keys()[1])
      send_response(peer, get_more, bson.document({
        { "ok", 0 },
        { "code", 50 },
        { "errmsg", "resume from operation time" },
        { "errorLabels", bson.array({ "ResumableChangeStreamError" }) },
      }))

      local resumed_aggregate = receive_frame(peer)
      local resumed_stage =
        resumed_aggregate.body:get("pipeline"):get(1):get("$changeStream")

      assert.are.equal(1, #resumed_stage)
      assert.are.equal(
        operation_time,
        resumed_stage:get("startAtOperationTime")
      )
      assert.is_nil(resumed_stage:get("resumeAfter"))
      assert.is_nil(resumed_stage:get("startAfter"))
      send_response(peer, resumed_aggregate, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({ event }) },
        }) },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          { runtime = mongodb.runtime.copas() }
        ))
        local collection = assert(client:database():collection("events"))
        local stream = assert(collection:watch())
        local change = assert(stream:try_next())

        assert.are.equal("insert", change:get("operationType"))
        assert.are.equal("resumed", change:get("_id"):get("token"))
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("watches a database with the returned cursor namespaces", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local resume_token = bson.document({ { "token", "database-position" } })
    local event = bson.document({
      { "_id", bson.document({ { "token", "database-event" } }) },
      { "operationType", "insert" },
    })
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local aggregate = receive_frame(peer)

      assert.are.equal(1, aggregate.body:get("aggregate"):to_number())
      assert.are.equal("app", aggregate.body:get("$db"))
      send_response(peer, aggregate, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(60) },
          { "ns", "app.database_changes" },
          { "firstBatch", bson.array({}) },
          { "postBatchResumeToken", resume_token },
        }) },
      }))

      local get_more = receive_frame(peer)

      assert.are.equal("database_changes", get_more.body:get("collection"))
      send_response(peer, get_more, bson.document({
        { "ok", 0 },
        { "code", 50 },
        { "errmsg", "resume database watch" },
        { "errorLabels", bson.array({ "ResumableChangeStreamError" }) },
      }))

      local resumed_aggregate = receive_frame(peer)
      local resumed_stage =
        resumed_aggregate.body:get("pipeline"):get(1):get("$changeStream")

      assert.are.equal(1, resumed_aggregate.body:get("aggregate"):to_number())
      assert.are.equal(
        "database-position",
        resumed_stage:get("resumeAfter"):get("token")
      )
      send_response(peer, resumed_aggregate, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(61) },
          { "ns", "app.resumed_database_changes" },
          { "firstBatch", bson.array({ event }) },
        }) },
      }))

      local kill = receive_frame(peer)

      assert.are.equal("resumed_database_changes", kill.body:get("killCursors"))
      assert.are.equal(61, kill.body:get("cursors"):get(1):to_number())
      send_response(peer, kill, bson.document({ { "ok", 1 } }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          { runtime = mongodb.runtime.copas() }
        ))
        local database = assert(client:database())
        local stream = assert(database:watch())
        local change = assert(stream:next())

        assert.are.equal("insert", change:get("operationType"))
        assert.are.equal("database-event", change:get("_id"):get("token"))
        assert.is_true(stream:close())
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("watches a cluster through admin with returned cursor namespaces", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local resume_token = bson.document({ { "token", "cluster-position" } })
    local event = bson.document({
      { "_id", bson.document({ { "token", "cluster-event" } }) },
      { "operationType", "insert" },
    })
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local aggregate = receive_frame(peer)
      local initial_stage =
        aggregate.body:get("pipeline"):get(1):get("$changeStream")

      assert.are.equal(1, aggregate.body:get("aggregate"):to_number())
      assert.are.equal("admin", aggregate.body:get("$db"))
      assert.is_true(initial_stage:get("allChangesForCluster"))
      send_response(peer, aggregate, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(70) },
          { "ns", "admin.cluster_changes" },
          { "firstBatch", bson.array({}) },
          { "postBatchResumeToken", resume_token },
        }) },
      }))

      local get_more = receive_frame(peer)

      assert.are.equal("cluster_changes", get_more.body:get("collection"))
      send_response(peer, get_more, bson.document({
        { "ok", 0 },
        { "code", 50 },
        { "errmsg", "resume cluster watch" },
        { "errorLabels", bson.array({ "ResumableChangeStreamError" }) },
      }))

      local resumed_aggregate = receive_frame(peer)
      local resumed_stage =
        resumed_aggregate.body:get("pipeline"):get(1):get("$changeStream")

      assert.are.equal(1, resumed_aggregate.body:get("aggregate"):to_number())
      assert.are.equal("admin", resumed_aggregate.body:get("$db"))
      assert.is_true(resumed_stage:get("allChangesForCluster"))
      assert.are.equal(
        "cluster-position",
        resumed_stage:get("resumeAfter"):get("token")
      )
      send_response(peer, resumed_aggregate, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(71) },
          { "ns", "admin.resumed_cluster_changes" },
          { "firstBatch", bson.array({ event }) },
        }) },
      }))

      local kill = receive_frame(peer)

      assert.are.equal("resumed_cluster_changes", kill.body:get("killCursors"))
      assert.are.equal(71, kill.body:get("cursors"):get(1):to_number())
      send_response(peer, kill, bson.document({ { "ok", 1 } }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          { runtime = mongodb.runtime.copas() }
        ))
        local stream = assert(client:watch())
        local change = assert(stream:next())

        assert.are.equal("insert", change:get("operationType"))
        assert.are.equal("cluster-event", change:get("_id"):get("token"))
        assert.is_true(stream:close())
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
