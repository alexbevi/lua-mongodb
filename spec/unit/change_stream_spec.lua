local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")

describe("collection change streams", function()
  it("opens, yields from, and closes a collection stream", function()
    local commands = {}
    local event = bson.document({
      { "_id", bson.document({ { "token", 1 } }) },
      { "operationType", "insert" },
    })
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(42) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({ event }) },
        }) },
      }),
      bson.document({ { "ok", 1 } }),
    }
    local executor = {
      close = function()
        return true
      end,
      command = function(_, database, command, options)
        commands[#commands + 1] = {
          command = command,
          database = database,
          options = options,
        }
        return table.remove(responses, 1)
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local collection = assert(client:database("app"):collection("events"))
    local match = bson.document({
      { "$match", bson.document({ { "operationType", "insert" } }) },
    })
    local stream = assert(collection:watch(bson.array({ match })))

    assert.are.equal("mongodb.change_stream", getmetatable(stream))
    assert.is_nil(stream.cursor)
    assert.are.equal(event, assert(stream:next()))
    assert.is_true(stream:close())
    assert.is_true(stream:is_closed())

    local aggregate = commands[1]
    local pipeline = aggregate.command:get("pipeline")

    assert.are.equal("app", aggregate.database)
    assert.are.equal("aggregate", aggregate.command:keys()[1])
    assert.are.equal("events", aggregate.command:get("aggregate"))
    assert.are.equal(2, #pipeline)
    assert.are.equal("$changeStream", pipeline:get(1):keys()[1])
    assert.are.equal(0, #pipeline:get(1):get("$changeStream"))
    assert.are.equal(match, pipeline:get(2))
    assert.is_true(aggregate.options.retryable_read)

    local kill = commands[2]

    assert.are.equal("killCursors", kill.command:keys()[1])
    assert.are.equal("events", kill.command:get("killCursors"))
    assert.are.equal(42, kill.command:get("cursors"):get(1):to_number())
  end)
end)
