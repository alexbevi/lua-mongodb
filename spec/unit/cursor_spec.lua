local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")

describe("find cursor lifecycle", function()
  it("iterates firstBatch/getMore and kills a live cursor on close", function()
    local commands = {}
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(41) },
          { "ns", "app.users" },
          { "firstBatch", bson.array({ bson.document({ { "n", 1 } }) }) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(42) },
          { "ns", "app.users" },
          { "nextBatch", bson.array({ bson.document({ { "n", 2 } }) }) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursorsKilled", bson.array({ bson.int64(42) }) },
      }),
    }
    local executor = {
      close = function(self)
        self.closed = true
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
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local collection = assert(client:database("app"):collection("users"))
    local cursor = assert(collection:find(
      bson.document({ { "active", true } }),
      { batch_size = 2, limit = 5 }
    ))

    assert.are.equal(1, assert(cursor:next()):get("n"))
    assert.are.equal(2, assert(cursor:next()):get("n"))
    assert.are.equal("find", commands[1].command:keys()[1])
    assert.are.equal(2, commands[1].command:get("batchSize"))
    assert.are.equal(5, commands[1].command:get("limit"))
    assert.are.equal("getMore", commands[2].command:keys()[1])
    assert.are.equal(41, commands[2].command:get("getMore"):to_number())
    assert.are.equal(2, commands[2].command:get("batchSize"))
    assert.is_true(cursor:close())
    assert.is_false(cursor:close())
    assert.are.equal("killCursors", commands[3].command:keys()[1])
    assert.are.equal(42, commands[3].command:get("cursors"):get(1):to_number())
    assert.is_false(executor.closed == true)
  end)

  it("exhausts cleanly and applies remaining limits to getMore", function()
    local commands = {}
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(70) },
          { "ns", "app.items" },
          { "firstBatch", bson.array({ bson.document({ { "n", 1 } }) }) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(71) },
          { "ns", "app.items" },
          { "nextBatch", bson.array({ bson.document({ { "n", 2 } }) }) },
        }) },
      }),
      bson.document({ { "ok", 1 } }),
    }
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command
        return table.remove(responses, 1)
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("items"):find(nil, {
      batch_size = 2,
      limit = 2,
    }))

    assert.are.equal(3, commands[1]:get("batchSize"))
    assert.are.equal(1, assert(cursor:next()):get("n"))
    assert.are.equal(2, assert(cursor:next()):get("n"))
    assert.are.equal(1, commands[2]:get("batchSize"))
    assert.is_nil(cursor:next())
    assert.are.equal("killCursors", commands[3]:keys()[1])
    assert.is_true(cursor:is_closed())
    assert.are.equal(2, cursor.retrieved)
  end)

  it("kills registered cursors before client shutdown and returns getMore errors", function()
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(90) },
          { "ns", "app.logs" },
          { "firstBatch", bson.array({}) },
        }) },
      }),
    }
    local executor = {
      close = function(self)
        self.closed = true
        return true
      end,
      command = function(_, _, command)
        if command:keys()[1] == "getMore" then
          return nil, errors.new({
            category = errors.CATEGORY.NETWORK,
            message = "getMore failed",
          })
        end

        return table.remove(responses, 1)
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("logs"):find())
    local document, err = cursor:next()

    assert.is_nil(document)
    assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
    assert.is_true(cursor:is_closed())

    responses[1] = bson.document({
      { "ok", 1 },
      { "cursor", bson.document({
        { "id", bson.int64(91) },
        { "ns", "app.logs" },
        { "firstBatch", bson.array({ bson.document({ { "n", 1 } }) }) },
      }) },
    })
    responses[2] = bson.document({ { "ok", 1 } })
    cursor = assert(client:database("app"):collection("logs"):find())

    assert.is_true(client:close())
    assert.is_true(executor.closed)
    assert.is_true(cursor:is_closed())
    document, err = cursor:next()
    assert.is_nil(document)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
  end)

  it("closes locally when a zero-id nextBatch is exhausted", function()
    local command_count = 0
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(10) },
          { "firstBatch", bson.array({ bson.document({ { "n", 1 } }) }) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "nextBatch", bson.array({ bson.document({ { "n", 2 } }) }) },
        }) },
      }),
    }
    local executor = {
      close = function()
        return true
      end,
      command = function()
        command_count = command_count + 1
        return table.remove(responses, 1)
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("items"):find())

    assert.are.equal(1, assert(cursor:next()):get("n"))
    assert.are.equal(2, assert(cursor:next()):get("n"))
    assert.is_true(cursor:is_closed())
    assert.is_nil(cursor:next())
    assert.are.equal(2, command_count)
  end)
end)
