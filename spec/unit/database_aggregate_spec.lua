local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")

describe("database aggregate", function()
  it("returns a cursor for an aggregate command against the database", function()
    local sent
    local executor = {
      close = function()
        return true
      end,
      command = function(_, database, command, options)
        sent = {
          command = command,
          database = database,
          options = options,
        }
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "app.$cmd.aggregate" },
            { "firstBatch", bson.array({
              bson.document({ { "value", 42 } }),
            }) },
          }) },
        })
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      read_concern = { level = "majority" },
      read_preference = { mode = "secondaryPreferred" },
    }))
    local database = assert(api.new_client(executor, config):database("app"))
    local pipeline = bson.array({
      bson.document({ { "$documents", bson.array({
        bson.document({ { "value", 42 } }),
      }) } }),
    })
    local cursor = assert(database:aggregate(pipeline, {
      allow_disk_use = true,
      batch_size = 2,
      comment = "database aggregate",
    }))

    assert.are.equal(42, assert(cursor:next()):get("value"))
    assert.is_nil(cursor:next())
    assert.are.equal("app", sent.database)
    assert.are.equal("aggregate", sent.command:keys()[1])
    assert.are.equal(1, sent.command:get("aggregate"))
    assert.are.equal(pipeline, sent.command:get("pipeline"))
    assert.are.equal(2, sent.command:get("cursor"):get("batchSize"))
    assert.is_true(sent.command:get("allowDiskUse"))
    assert.are.equal("database aggregate", sent.command:get("comment"))
    assert.are.equal("majority", sent.command:get("readConcern"):get("level"))
    assert.are.equal("secondary_preferred", sent.options.read_preference.mode)
    assert.is_true(sent.options.retryable_read)
  end)
end)
