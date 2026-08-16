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
    request_id = 2100 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("administration commands over OP_MSG", function()
  it("manages databases, collections, and indexes", function()
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
        { "maxBsonObjectSize", 16 * 1024 * 1024 },
        { "maxMessageSizeBytes", 48000000 },
        { "maxWireVersion", 25 },
        { "maxWriteBatchSize", 100000 },
      }))

      local create = receive_frame(peer)
      assert.are.equal("create", create.body:keys()[1])
      assert.are.equal("events", create.body:get("create"))
      send_response(peer, create, bson.document({ { "ok", 1 } }))

      local create_indexes = receive_frame(peer)
      assert.are.equal("createIndexes", create_indexes.body:keys()[1])
      assert.are.equal("kind_1", create_indexes.body:get("indexes"):get(1):get("name"))
      send_response(peer, create_indexes, bson.document({ { "ok", 1 } }))

      local create_search_index = receive_frame(peer)
      assert.are.equal("createSearchIndexes", create_search_index.body:keys()[1])
      assert.are.equal(
        "vectorSearch",
        create_search_index.body:get("indexes"):get(1):get("type")
      )
      send_response(peer, create_search_index, bson.document({
        { "ok", 1 },
        { "indexesCreated", bson.array({
          bson.document({ { "name", "plot-vector" } }),
        }) },
      }))

      local create_search_indexes = receive_frame(peer)
      assert.are.equal("createSearchIndexes", create_search_indexes.body:keys()[1])
      assert.are.equal(2, #create_search_indexes.body:get("indexes"))
      send_response(peer, create_search_indexes, bson.document({
        { "ok", 1 },
        { "indexesCreated", bson.array({
          bson.document({ { "name", "search-a" } }),
          bson.document({ { "name", "search-b" } }),
        }) },
      }))

      local list_search_indexes = receive_frame(peer)
      local search_stage = list_search_indexes.body:get("pipeline")
        :get(1):get("$listSearchIndexes")

      assert.are.equal("aggregate", list_search_indexes.body:keys()[1])
      assert.are.equal("search-a", search_stage:get("name"))
      assert.are.equal(
        10,
        list_search_indexes.body:get("cursor"):get("batchSize"):to_number()
      )
      assert.is_nil(list_search_indexes.body:get("readConcern"))
      assert.is_nil(list_search_indexes.body:get("writeConcern"))
      send_response(peer, list_search_indexes, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({
            bson.document({ { "name", "search-a" } }),
          }) },
        }) },
      }))

      local update_search_index = receive_frame(peer)

      assert.are.equal("updateSearchIndex", update_search_index.body:keys()[1])
      assert.are.equal("search-a", update_search_index.body:get("name"))
      assert.is_false(
        update_search_index.body:get("definition"):get("mappings"):get("dynamic")
      )
      send_response(peer, update_search_index, bson.document({ { "ok", 1 } }))

      local drop_search_index = receive_frame(peer)

      assert.are.equal("dropSearchIndex", drop_search_index.body:keys()[1])
      assert.are.equal("search-a", drop_search_index.body:get("name"))
      send_response(peer, drop_search_index, bson.document({ { "ok", 1 } }))

      local list_indexes = receive_frame(peer)
      assert.are.equal("listIndexes", list_indexes.body:keys()[1])
      send_response(peer, list_indexes, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({
            bson.document({ { "name", "_id_" } }),
            bson.document({ { "name", "kind_1" } }),
          }) },
        }) },
      }))

      local list_collections = receive_frame(peer)
      assert.are.equal("listCollections", list_collections.body:keys()[1])
      assert.is_true(list_collections.body:get("nameOnly"))
      send_response(peer, list_collections, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.$cmd.listCollections" },
          { "firstBatch", bson.array({
            bson.document({ { "name", "events" } }),
          }) },
        }) },
      }))

      local list_databases = receive_frame(peer)
      assert.are.equal("listDatabases", list_databases.body:keys()[1])
      assert.is_true(list_databases.body:get("nameOnly"))
      send_response(peer, list_databases, bson.document({
        { "ok", 1 },
        { "databases", bson.array({
          bson.document({ { "name", "app" } }),
        }) },
      }))

      local drop_index = receive_frame(peer)
      assert.are.equal("dropIndexes", drop_index.body:keys()[1])
      assert.are.equal("kind_1", drop_index.body:get("index"))
      send_response(peer, drop_index, bson.document({ { "ok", 1 } }))

      local drop_collection = receive_frame(peer)
      assert.are.equal("drop", drop_collection.body:keys()[1])
      send_response(peer, drop_collection, bson.document({ { "ok", 1 } }))

      local drop_database = receive_frame(peer)
      assert.are.equal("dropDatabase", drop_database.body:keys()[1])
      send_response(peer, drop_database, bson.document({ { "ok", 1 } }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          { runtime = mongodb.runtime.copas() }
        ))
        local database = client:database()
        local collection = assert(database:create_collection("events"))

        assert.are.equal(
          "kind_1",
          assert(collection:create_index(bson.document({ { "kind", 1 } })))
        )
        assert.are.equal("plot-vector", assert(collection:create_search_index(
          bson.document({
            { "definition", bson.document({
              { "fields", bson.array({
                bson.document({
                  { "type", "vector" },
                  { "path", "plot_embedding" },
                  { "numDimensions", 1536 },
                  { "similarity", "euclidean" },
                }),
              }) },
            }) },
            { "name", "plot-vector" },
            { "type", "vectorSearch" },
          })
        )))
        local search_names = assert(collection:create_search_indexes({
          bson.document({
            { "definition", bson.document({ { "mappings", bson.document({}) } }) },
            { "name", "search-a" },
          }),
          bson.document({
            { "definition", bson.document({ { "mappings", bson.document({}) } }) },
            { "name", "search-b" },
          }),
        }))

        assert.are.same(
          { "search-a", "search-b" },
          { search_names[1], search_names[2] }
        )
        local search_indexes = assert(collection:list_search_indexes("search-a", {
          batch_size = 10,
        }))

        assert.are.equal("search-a", assert(search_indexes:next()):get("name"))
        assert.is_true(collection:update_search_index("search-a", bson.document({
          { "mappings", bson.document({ { "dynamic", false } }) },
        })))
        assert.is_true(collection:drop_search_index("search-a"))
        local indexes = assert(collection:list_indexes())

        assert.are.equal("_id_", assert(indexes:next()):get("name"))
        assert.are.equal("kind_1", assert(indexes:next()):get("name"))
        local collections = assert(database:list_collection_names())
        local databases = assert(client:list_database_names())

        assert.are.equal("events", collections[1])
        assert.are.equal("app", databases[1])
        assert.is_true(collection:drop_index("kind_1"))
        assert.is_true(collection:drop())
        assert.is_true(client:drop_database("app"))
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
