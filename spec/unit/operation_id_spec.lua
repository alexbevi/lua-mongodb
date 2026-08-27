local api = require("mongodb.api")
local bson = require("mongodb.bson")
local bulk = require("mongodb.bulk")
local client_bulk = require("mongodb.client_bulk")
local driver_options = require("mongodb.config.options")
local operation_id = require("mongodb.operation_id")
local retry_executor = require("mongodb.retry_executor")

describe("logical operation identities", function()
  it("allocates distinct positive identities and wraps after the signed 32-bit maximum", function()
    local ids = operation_id.generator(0x7ffffffe)

    assert.are.equal(0x7ffffffe, ids:next())
    assert.are.equal(0x7fffffff, ids:next())
    assert.are.equal(1, ids:next())
    assert.has_error(function()
      ids.next_id = 1
    end, "MongoDB operation ID generators are immutable")
    assert.has_error(function()
      operation_id.generator(0)
    end, "first operation ID must be an integer from 1 through 2147483647")

    local first = operation_id.next()
    local second = operation_id.next()

    assert.is_true(first > 0)
    assert.is_true(second > 0)
    assert.are_not.equal(first, second)
  end)

  it("shares one sequence across retry, collection bulk, and client bulk execution", function()
    local observed = {}
    local underlying = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
          max_write_batch_size = 1000,
        }
      end,
      command = function(_, _, command, options)
        local name = command:keys()[1]

        observed[#observed + 1] = {
          name = name,
          operation_id = options.operation_id,
        }

        if name == "bulkWrite" then
          return bson.document({
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
          })
        end

        return bson.document({ { "ok", 1 }, { "n", 1 } })
      end,
    }
    local executor = retry_executor.new(underlying, {
      enabled = true,
      enabled_writes = true,
    })

    assert(executor:command(
      "app",
      bson.document({ { "find", "events" } }),
      { retryable_read = true }
    ))

    local client = api.new_client(executor, assert(driver_options.normalize(nil, {})))
    local collection = assert(client:database("app"):collection("events"))

    assert(collection:bulk_write({
      bulk.insert_one(bson.document({ { "_id", 1 } })),
    }))
    assert(client:bulk_write({
      client_bulk.insert_one("app.events", bson.document({ { "_id", 2 } })),
    }))

    assert.are.same({ "find", "insert", "bulkWrite" }, {
      observed[1].name,
      observed[2].name,
      observed[3].name,
    })

    for _, event in ipairs(observed) do
      assert.is_true(event.operation_id > 0)
    end

    assert.are_not.equal(observed[1].operation_id, observed[2].operation_id)
    assert.are_not.equal(observed[2].operation_id, observed[3].operation_id)
    assert.are_not.equal(observed[1].operation_id, observed[3].operation_id)
  end)
end)
