local api = require("mongodb.api")
local bson = require("mongodb.bson")
local client_bulk = require("mongodb.client_bulk")
local driver_options = require("mongodb.config.options")

describe("client bulk writes", function()
  it("inserts across namespaces with deduplicated namespace information", function()
    local captured
    local next_id = 0
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
          max_write_batch_size = 100000,
        }
      end,
      command = function(_, database, command, options)
        captured = {
          command = command,
          database = database,
          options = options,
        }
        return bson.document({
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
        })
      end,
    }
    local object_ids = {
      new = function()
        next_id = next_id + 1
        return bson.object_id(string.format("%024x", next_id))
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config, nil, nil, object_ids)
    local first = bson.document({ { "kind", "first" } })
    local second = bson.document({ { "_id", 40 }, { "kind", "second" } })
    local third = bson.document({ { "kind", "third" } })
    local first_model = client_bulk.insert_one("app.events", first)
    local written = assert(client:bulk_write({
      first_model,
      client_bulk.insert_one("audit.events", second),
      client_bulk.insert_one("app.events", third),
    }))

    assert.is_true(written.acknowledged)
    assert.are.equal(3, written.inserted_count)
    assert.are.equal(0, written.matched_count)
    assert.are.equal(0, written.modified_count)
    assert.are.equal(0, written.upserted_count)
    assert.are.equal(0, written.deleted_count)
    assert.are.equal("admin", captured.database)
    assert.are.equal("bulkWrite", captured.command:keys()[1])
    assert.is_true(captured.command:get("errorsOnly"))
    assert.is_true(captured.command:get("ordered"))

    local ops = captured.options.sequences[1]
    local namespaces = captured.options.sequences[2]

    assert.are.equal("ops", ops.identifier)
    assert.are.equal("nsInfo", namespaces.identifier)
    assert.are.equal(3, #ops.documents)
    assert.are.equal(2, #namespaces.documents)
    assert.are.equal(0, ops.documents[1]:get("insert"):to_number())
    assert.are.equal(1, ops.documents[2]:get("insert"):to_number())
    assert.are.equal(0, ops.documents[3]:get("insert"):to_number())
    assert.are.equal("app.events", namespaces.documents[1]:get("ns"))
    assert.are.equal("audit.events", namespaces.documents[2]:get("ns"))
    assert.are.equal("_id", ops.documents[1]:get("document"):keys()[1])
    assert.are.equal("_id", ops.documents[3]:get("document"):keys()[1])
    assert.are.equal(
      bson.object_id("000000000000000000000001"),
      ops.documents[1]:get("document"):get("_id")
    )
    assert.are.equal(
      bson.object_id("000000000000000000000002"),
      ops.documents[3]:get("document"):get("_id")
    )
    assert.are.equal(40, ops.documents[2]:get("document"):get("_id"))
    assert.is_nil(first:get("_id"))
    assert.is_nil(third:get("_id"))
    assert.has_error(function()
      first_model.kind = "delete"
    end, "client bulk write models are immutable")
    assert.has_error(function()
      written.inserted_count = 4
    end, "client bulk result values are immutable")
  end)
end)
