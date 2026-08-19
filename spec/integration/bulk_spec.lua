local bson = require("mongodb.bson")
local copas = require("copas")
local errors = require("mongodb.error")
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
    request_id = 1600 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("collection bulk writes over OP_MSG", function()
  it("splits document sequences at the negotiated message size", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxBsonObjectSize", 1024 },
        { "maxMessageSizeBytes", 250 },
        { "maxWireVersion", 25 },
        { "maxWriteBatchSize", 100 },
      }))

      for identifier = 1, 2 do
        local insert = receive_frame(peer)

        assert.are.equal("insert", insert.body:keys()[1])
        assert.are.equal(1, #insert.sequences)
        assert.are.equal("documents", insert.sequences[1].identifier)
        assert.are.equal(1, #insert.sequences[1].documents)
        assert.are.equal(
          identifier,
          insert.sequences[1].documents[1]:get("_id"):to_number()
        )
        send_response(peer, insert, bson.document({ { "ok", 1 }, { "n", 1 } }))
      end
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          { runtime = mongodb.runtime.copas() }
        ))
        local collection = assert(client:database():collection("events"))
        local inserted = assert(collection:insert_many({
          bson.document({ { "_id", 1 }, { "payload", string.rep("a", 100) } }),
          bson.document({ { "_id", 2 }, { "payload", string.rep("b", 100) } }),
        }))

        assert.are.equal(2, #inserted.inserted_ids)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("writes inserts for multiple namespaces in one client command", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxBsonObjectSize", 16777216 },
        { "maxMessageSizeBytes", 48000000 },
        { "maxWireVersion", 25 },
        { "maxWriteBatchSize", 100000 },
      }))

      local request = receive_frame(peer)

      assert.are.equal("bulkWrite", request.body:keys()[1])
      assert.are.equal("admin", request.body:get("$db"))
      assert.are.equal(2, #request.sequences)
      assert.are.equal("ops", request.sequences[1].identifier)
      assert.are.equal("nsInfo", request.sequences[2].identifier)
      assert.are.equal(3, #request.sequences[1].documents)
      assert.are.equal(2, #request.sequences[2].documents)
      assert.are.equal(
        0,
        request.sequences[1].documents[1]:get("insert"):to_number()
      )
      assert.are.equal(
        1,
        request.sequences[1].documents[2]:get("insert"):to_number()
      )
      assert.are.equal(
        0,
        request.sequences[1].documents[3]:get("insert"):to_number()
      )
      assert.are.equal(
        "app.events",
        request.sequences[2].documents[1]:get("ns")
      )
      assert.are.equal(
        "audit.events",
        request.sequences[2].documents[2]:get("ns")
      )
      send_response(peer, request, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "admin.$cmd.bulkWrite" },
          { "firstBatch", bson.array({}) },
        }) },
        { "nErrors", 0 },
        { "nInserted", 3 },
        { "nMatched", 0 },
        { "nModified", 0 },
        { "nUpserted", 0 },
        { "nDeleted", 0 },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port,
          { runtime = mongodb.runtime.copas() }
        ))
        local written = assert(client:bulk_write({
          mongodb.client_bulk.insert_one(
            "app.events",
            bson.document({ { "_id", 1 } })
          ),
          mongodb.client_bulk.insert_one(
            "audit.events",
            bson.document({ { "_id", 2 } })
          ),
          mongodb.client_bulk.insert_one(
            "app.events",
            bson.document({ { "_id", 3 } })
          ),
        }))

        assert.are.equal(3, written.inserted_count)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("splits client bulk writes at maxWriteBatchSize", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxBsonObjectSize", 16777216 },
        { "maxMessageSizeBytes", 48000000 },
        { "maxWireVersion", 25 },
        { "maxWriteBatchSize", 2 },
      }))

      for batch_index, expected_count in ipairs({ 2, 1 }) do
        local request = receive_frame(peer)
        local operations = request.sequences[1].documents
        local namespaces = request.sequences[2].documents

        assert.are.equal("bulkWrite", request.body:keys()[1])
        assert.are.equal(expected_count, #operations)
        assert.are.equal(expected_count, #namespaces)
        assert.are.equal(0, operations[1]:get("insert"):to_number())

        if batch_index == 1 then
          assert.are.equal(1, operations[2]:get("insert"):to_number())
          assert.are.equal("app.events", namespaces[1]:get("ns"))
          assert.are.equal("audit.events", namespaces[2]:get("ns"))
        else
          assert.are.equal("archive.events", namespaces[1]:get("ns"))
        end

        send_response(peer, request, bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "admin.$cmd.bulkWrite" },
            { "firstBatch", bson.array({}) },
          }) },
          { "nErrors", 0 },
          { "nInserted", expected_count },
          { "nMatched", 0 },
          { "nModified", 0 },
          { "nUpserted", 0 },
          { "nDeleted", 0 },
        }))
      end
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port,
          { runtime = mongodb.runtime.copas() }
        ))
        local result = assert(client:bulk_write({
          mongodb.client_bulk.insert_one(
            "app.events",
            bson.document({ { "_id", 1 } })
          ),
          mongodb.client_bulk.insert_one(
            "audit.events",
            bson.document({ { "_id", 2 } })
          ),
          mongodb.client_bulk.insert_one(
            "archive.events",
            bson.document({ { "_id", 3 } })
          ),
        }))

        assert.are.equal(3, result.inserted_count)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("splits client bulk writes when nsInfo crosses the message limit", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome
    local first_namespace = "app.events"
    local second_namespace = "app." .. string.rep("archive", 8)
    local first_document = bson.document({ { "_id", 1 }, { "value", "a" } })
    local second_document = bson.document({ { "_id", 2 }, { "value", "b" } })
    local command = bson.document({
      { "bulkWrite", 1 },
      { "errorsOnly", true },
      { "ordered", true },
    })
    local first_operation = bson.document({
      { "insert", bson.int32(0) },
      { "document", first_document },
    })
    local second_operation = bson.document({
      { "insert", bson.int32(0) },
      { "document", second_document },
    })
    local function encoded_size(document)
      return #assert(bson.encode(document, {
        max_binary_size = 100000,
        max_document_size = 100000,
        max_string_size = 100000,
      }))
    end
    local max_message_size = 1000
      + encoded_size(command)
      + encoded_size(first_operation)
      + encoded_size(bson.document({ { "ns", first_namespace } }))
      + encoded_size(second_operation)

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxBsonObjectSize", 16777216 },
        { "maxMessageSizeBytes", max_message_size },
        { "maxWireVersion", 25 },
        { "maxWriteBatchSize", 100 },
      }))

      for _, namespace in ipairs({ first_namespace, second_namespace }) do
        local request = receive_frame(peer)

        assert.are.equal("bulkWrite", request.body:keys()[1])
        assert.are.equal(1, #request.sequences[1].documents)
        assert.are.equal(1, #request.sequences[2].documents)
        assert.are.equal(
          0,
          request.sequences[1].documents[1]:get("insert"):to_number()
        )
        assert.are.equal(namespace, request.sequences[2].documents[1]:get("ns"))
        send_response(peer, request, bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "admin.$cmd.bulkWrite" },
            { "firstBatch", bson.array({}) },
          }) },
          { "nErrors", 0 },
          { "nInserted", 1 },
          { "nMatched", 0 },
          { "nModified", 0 },
          { "nUpserted", 0 },
          { "nDeleted", 0 },
        }))
      end
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port,
          { runtime = mongodb.runtime.copas() }
        ))
        local result = assert(client:bulk_write({
          mongodb.client_bulk.insert_one(first_namespace, first_document),
          mongodb.client_bulk.insert_one(second_namespace, second_document),
        }))

        assert.are.equal(2, result.inserted_count)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("merges client bulk failures across transport batches", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxBsonObjectSize", 16777216 },
        { "maxMessageSizeBytes", 48000000 },
        { "maxWireVersion", 25 },
        { "maxWriteBatchSize", 1 },
      }))

      local first = receive_frame(peer)

      assert.are.equal("bulkWrite", first.body:keys()[1])
      assert.are.equal(1, #first.sequences[1].documents)
      send_response(peer, first, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "admin.$cmd.bulkWrite" },
          { "firstBatch", bson.array({
            bson.document({ { "ok", 1 }, { "idx", 0 }, { "n", 1 } }),
          }) },
        }) },
        { "nErrors", 0 },
        { "nInserted", 1 },
        { "nMatched", 0 },
        { "nModified", 0 },
        { "nUpserted", 0 },
        { "nDeleted", 0 },
        { "writeConcernError", bson.document({
          { "code", 91 },
          { "errmsg", "first batch concern" },
        }) },
      }))

      local second = receive_frame(peer)

      assert.are.equal("bulkWrite", second.body:keys()[1])
      assert.are.equal(1, #second.sequences[1].documents)
      send_response(peer, second, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "admin.$cmd.bulkWrite" },
          { "firstBatch", bson.array({
            bson.document({
              { "ok", 0 },
              { "idx", 0 },
              { "code", 11000 },
              { "errmsg", "second batch duplicate" },
            }),
          }) },
        }) },
        { "nErrors", 1 },
        { "nInserted", 0 },
        { "nMatched", 0 },
        { "nModified", 0 },
        { "nUpserted", 0 },
        { "nDeleted", 0 },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port,
          { runtime = mongodb.runtime.copas() }
        ))
        local result, err = client:bulk_write({
          mongodb.client_bulk.insert_one(
            "app.events",
            bson.document({ { "_id", 1 } })
          ),
          mongodb.client_bulk.insert_one(
            "app.events",
            bson.document({ { "_id", 2 } })
          ),
        }, { ordered = false, verbose_results = true })

        assert.is_nil(result)
        assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
        assert.are.equal(1, #err.details.write_errors)
        assert.are.equal(2, err.details.write_errors[1].index)
        assert.are.equal(11000, err.details.write_errors[1].code)
        assert.are.equal(1, #err.details.write_concern_errors)
        assert.are.equal(91, err.details.write_concern_errors[1].code)
        assert.are.equal(1, err.details.partial_result.inserted_count)
        assert.are.equal(
          1,
          err.details.partial_result.insert_results[1].inserted_id
        )
        assert.is_nil(err.details.partial_result.insert_results[2])
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("writes updates, replacements, and deletes across client namespaces", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxBsonObjectSize", 16777216 },
        { "maxMessageSizeBytes", 48000000 },
        { "maxWireVersion", 25 },
        { "maxWriteBatchSize", 100000 },
      }))

      local request = receive_frame(peer)
      local ops = request.sequences[1].documents
      local namespaces = request.sequences[2].documents

      assert.are.equal("bulkWrite", request.body:keys()[1])
      assert.is_false(request.body:get("errorsOnly"))
      assert.are.equal(5, #ops)
      assert.are.equal(2, #namespaces)
      assert.are.equal(0, ops[1]:get("update"):to_number())
      assert.is_false(ops[1]:get("multi"))
      assert.are.equal(-1, ops[1]:get("sort"):get("_id"):to_number())
      assert.are.equal(0, ops[2]:get("update"):to_number())
      assert.is_true(ops[2]:get("multi"))
      assert.are.equal(1, ops[3]:get("update"):to_number())
      assert.is_false(ops[3]:get("multi"))
      assert.are.equal(0, ops[4]:get("delete"):to_number())
      assert.is_false(ops[4]:get("multi"))
      assert.are.equal("_id_", ops[4]:get("hint"))
      assert.are.equal(1, ops[5]:get("delete"):to_number())
      assert.is_true(ops[5]:get("multi"))
      assert.are.equal("simple", ops[5]:get("collation"):get("locale"))
      assert.are.equal("app.events", namespaces[1]:get("ns"))
      assert.are.equal("audit.events", namespaces[2]:get("ns"))
      send_response(peer, request, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(92) },
          { "ns", "admin.$cmd.bulkWrite" },
          { "firstBatch", bson.array({
            bson.document({
              { "ok", 1 }, { "idx", 0 }, { "n", 1 }, { "nModified", 1 },
            }),
            bson.document({
              { "ok", 1 }, { "idx", 1 }, { "n", 2 }, { "nModified", 1 },
            }),
            bson.document({
              { "ok", 1 }, { "idx", 2 }, { "n", 0 }, { "nModified", 0 },
            }),
          }) },
        }) },
        { "nErrors", 0 },
        { "nInserted", 0 },
        { "nMatched", 3 },
        { "nModified", 2 },
        { "nUpserted", 0 },
        { "nDeleted", 3 },
      }))

      local get_more = receive_frame(peer)

      assert.are.equal(92, get_more.body:get("getMore"):to_number())
      assert.are.equal("$cmd.bulkWrite", get_more.body:get("collection"))
      send_response(peer, get_more, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "admin.$cmd.bulkWrite" },
          { "nextBatch", bson.array({
            bson.document({ { "ok", 1 }, { "idx", 3 }, { "n", 1 } }),
            bson.document({ { "ok", 1 }, { "idx", 4 }, { "n", 2 } }),
          }) },
        }) },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port,
          { runtime = mongodb.runtime.copas() }
        ))
        local filter = bson.document({ { "_id", bson.document({ { "$gt", 1 } }) } })
        local written = assert(client:bulk_write({
          mongodb.client_bulk.update_one(
            "app.events",
            filter,
            bson.document({ { "$inc", bson.document({ { "count", 1 } }) } }),
            { sort = bson.document({ { "_id", -1 } }) }
          ),
          mongodb.client_bulk.update_many(
            "app.events",
            filter,
            bson.document({ { "$set", bson.document({ { "active", true } }) } })
          ),
          mongodb.client_bulk.replace_one(
            "audit.events",
            bson.document({ { "_id", 4 } }),
            bson.document({ { "archived", true } })
          ),
          mongodb.client_bulk.delete_one(
            "app.events",
            bson.document({ { "_id", 5 } }),
            { hint = "_id_" }
          ),
          mongodb.client_bulk.delete_many(
            "audit.events",
            bson.document({ { "archived", false } }),
            { collation = bson.document({ { "locale", "simple" } }) }
          ),
        }, { verbose_results = true }))

        assert.are.equal(3, written.matched_count)
        assert.are.equal(2, written.modified_count)
        assert.are.equal(3, written.deleted_count)
        assert.are.equal(1, written.update_results[1].matched_count)
        assert.are.equal(2, written.update_results[2].matched_count)
        assert.are.equal(1, written.delete_results[4].deleted_count)
        assert.are.equal(2, written.delete_results[5].deleted_count)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("closes a client result cursor after a getMore failure", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxBsonObjectSize", 16777216 },
        { "maxMessageSizeBytes", 48000000 },
        { "maxWireVersion", 25 },
        { "maxWriteBatchSize", 100000 },
      }))

      local request = receive_frame(peer)

      assert.are.equal("bulkWrite", request.body:keys()[1])
      send_response(peer, request, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(93) },
          { "ns", "admin.$cmd.bulkWrite" },
          { "firstBatch", bson.array({
            bson.document({ { "ok", 1 }, { "idx", 0 }, { "n", 1 } }),
          }) },
        }) },
        { "nErrors", 0 },
        { "nInserted", 2 },
        { "nMatched", 0 },
        { "nModified", 0 },
        { "nUpserted", 0 },
        { "nDeleted", 0 },
      }))

      local get_more = receive_frame(peer)

      assert.are.equal(93, get_more.body:get("getMore"):to_number())
      send_response(peer, get_more, bson.document({
        { "ok", 0 },
        { "code", bson.int32(8) },
        { "codeName", "UnknownError" },
        { "errmsg", "failpoint getMore error" },
        { "errorLabels", bson.array({ "RetryableWriteError" }) },
      }))

      local kill = receive_frame(peer)

      assert.are.equal("killCursors", kill.body:keys()[1])
      assert.are.equal("$cmd.bulkWrite", kill.body:get("killCursors"))
      assert.are.equal(93, kill.body:get("cursors"):get(1):to_number())
      send_response(peer, kill, bson.document({
        { "ok", 1 },
        { "cursorsKilled", bson.array({ bson.int64(93) }) },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port,
          { runtime = mongodb.runtime.copas() }
        ))
        local result, err = client:bulk_write({
          mongodb.client_bulk.insert_one(
            "app.events",
            bson.document({ { "_id", 1 } })
          ),
          mongodb.client_bulk.insert_one(
            "app.events",
            bson.document({ { "_id", 2 } })
          ),
        }, { verbose_results = true })

        assert.is_nil(result)
        assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
        assert.is_true(errors.is(err.cause, errors.CATEGORY.SERVER))
        assert.are.equal(8, err.cause.code)
        assert.are.equal(2, err.details.partial_result.inserted_count)
        assert.are.equal(
          1,
          err.details.partial_result.insert_results[1].inserted_id
        )
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
