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

  it("translates update and replacement models without changing their values", function()
    local captured
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
      command = function(_, _, _, options)
        captured = options
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "admin.$cmd.bulkWrite" },
            { "firstBatch", bson.array({}) },
          }) },
          { "nErrors", 0 },
          { "nInserted", 0 },
          { "nMatched", 2 },
          { "nModified", 1 },
          { "nUpserted", 1 },
          { "nDeleted", 0 },
        })
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local filter = bson.document({ { "name", "Ada" } })
    local array_filters = bson.array({
      bson.document({ { "item.active", true } }),
    })
    local collation = bson.document({ { "locale", "en" } })
    local sort = bson.document({ { "created_at", 1 } })
    local update = bson.document({
      { "$set", bson.document({ { "active", true } }) },
      { "later_field_does_not_control_validation", true },
    })
    local pipeline = bson.array({
      bson.document({ { "$set", bson.document({ { "seen", true } }) } }),
    })
    local replacement = bson.document({
      { "name", "Ada Lovelace" },
      { "$later_field_is_allowed", true },
    })
    local written = assert(client:bulk_write({
      client_bulk.update_one("app.users", filter, update, {
        array_filters = array_filters,
        collation = collation,
        hint = "by_name",
        sort = sort,
        upsert = true,
      }),
      client_bulk.update_many("app.users", filter, pipeline, {
        hint = bson.document({ { "name", 1 } }),
      }),
      client_bulk.replace_one("audit.users", filter, replacement, {
        collation = collation,
        sort = sort,
        upsert = true,
      }),
    }))

    assert.are.equal(2, written.matched_count)
    assert.are.equal(1, written.modified_count)
    assert.are.equal(1, written.upserted_count)

    local ops = captured.sequences[1].documents

    assert.are.equal(3, #ops)
    assert.are.equal(0, ops[1]:get("update"):to_number())
    assert.are.equal(0, ops[2]:get("update"):to_number())
    assert.are.equal(1, ops[3]:get("update"):to_number())
    assert.are.equal(filter, ops[1]:get("filter"))
    assert.are.equal(update, ops[1]:get("updateMods"))
    assert.is_false(ops[1]:get("multi"))
    assert.is_true(ops[1]:get("upsert"))
    assert.are.equal(array_filters, ops[1]:get("arrayFilters"))
    assert.are.equal(collation, ops[1]:get("collation"))
    assert.are.equal("by_name", ops[1]:get("hint"))
    assert.are.equal(sort, ops[1]:get("sort"))
    assert.are.equal(pipeline, ops[2]:get("updateMods"))
    assert.is_true(ops[2]:get("multi"))
    assert.are.equal(replacement, ops[3]:get("updateMods"))
    assert.is_false(ops[3]:get("multi"))
    assert.are.same({ "locale" }, collation:keys())
    assert.are.same({ "created_at" }, sort:keys())
    assert.has_error(function()
      client_bulk.update_one("app.users", filter, replacement)
    end, "update document must begin with an atomic '$' modifier")
    assert.has_error(function()
      client_bulk.replace_one("app.users", filter, update)
    end, "replacement document must not begin with an atomic modifier")
  end)
end)
