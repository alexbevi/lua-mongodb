local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")
local retry_executor = require("mongodb.retry_executor")

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

  it("retries read pipelines once but not write pipelines", function()
    local read_attempts = 0
    local write_attempts = 0
    local underlying = {
      capabilities = function()
        return { max_wire_version = 27 }
      end,
      close = function()
        return true
      end,
      command = function(_, _, command)
        local pipeline = command:get("pipeline")
        local final_stage = pipeline:get(#pipeline)
        local stage_name = final_stage:keys()[1]

        if stage_name == "$out" or stage_name == "$merge" then
          write_attempts = write_attempts + 1
          return nil, errors.new({
            category = errors.CATEGORY.SERVER,
            code = 10107,
            message = "not writable primary",
          })
        end

        read_attempts = read_attempts + 1

        if read_attempts == 1 then
          return nil, errors.new({
            category = errors.CATEGORY.SERVER,
            code = 10107,
            message = "not writable primary",
          })
        end

        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "app.$cmd.aggregate" },
            { "firstBatch", bson.array({}) },
          }) },
        })
      end,
    }
    local executor = retry_executor.new(underlying, { enabled_reads = true })
    local database = assert(api.new_client(
      executor,
      assert(driver_options.normalize())
    ):database("app"))
    local read_cursor = assert(database:aggregate(bson.array({
      bson.document({ { "$match", bson.document({}) } }),
    })))

    assert.is_nil(read_cursor:next())
    assert.are.equal(2, read_attempts)

    for _, stage in ipairs({
      bson.document({ { "$out", "archive" } }),
      bson.document({ { "$merge", "archive" } }),
    }) do
      local cursor, err = database:aggregate(bson.array({ stage }))

      assert.is_nil(cursor)
      assert.are.equal(10107, err.code)
    end

    assert.are.equal(2, write_attempts)
  end)
end)
