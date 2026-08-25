local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")

describe("core collection read and modify operations", function()
  it("builds aggregate, count, distinct, and findAndModify commands", function()
    local commands = {}
    local release_count = 0
    local pin = {
      release = function()
        release_count = release_count + 1
        return true
      end,
    }
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(42) },
          { "ns", "app.users" },
          { "firstBatch", bson.array({ bson.document({ { "n", 1 } }) }) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.users" },
          { "nextBatch", bson.array({ bson.document({ { "n", 2 } }) }) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.users" },
          { "firstBatch", bson.array({ bson.document({ { "n", 2 } }) }) },
        }) },
      }),
      bson.document({ { "ok", 1 }, { "n", 3 } }),
      bson.document({ { "ok", 1 }, { "values", bson.array({ "a", "b" }) } }),
      bson.document({ { "ok", 1 }, { "value", bson.document({ { "kind", "a" } }) } }),
      bson.document({ { "ok", 1 }, { "value", bson.document({ { "kind", "b" } }) } }),
      bson.document({ { "ok", 1 }, { "value", bson.document({ { "kind", "c" } }) } }),
    }
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return { max_wire_version = 27 }
      end,
      command = function(_, database, command, options)
        commands[#commands + 1] = {
          command = command,
          database = database,
          options = options,
        }

        if options.on_server_selected then
          options.on_server_selected("router-a:27017")
        end

        if #commands == 1 then
          assert.is_true(options.pin_connection)
          options.on_connection_pinned(pin)
        elseif command:get("getMore") ~= nil then
          assert.are.equal(pin, options.pinned_connection)
        end

        return table.remove(responses, 1)
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      read_concern = { level = "majority" },
      write_concern = { w = "majority" },
    }))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("users"))
    local filter = bson.document({ { "kind", "a" } })
    local cursor = assert(collection:aggregate(bson.array({
      bson.document({ { "$match", filter } }),
    }), {
      batch_size = 1,
      comment = "aggregate",
      max_await_time_ms = 25,
    }))

    assert.are.equal(1, assert(cursor:next()):get("n"))
    assert.are.equal(2, assert(cursor:next()):get("n"))
    assert.is_nil(cursor:next())
    assert.are.equal("aggregate", commands[1].command:keys()[1])
    assert.are.equal(1, commands[1].command:get("cursor"):get("batchSize"))
    assert.are.equal("getMore", commands[2].command:keys()[1])
    assert.are.equal(25, commands[2].command:get("maxTimeMS"))
    assert.are.equal("router-a:27017", commands[2].options.server_address)
    assert.are.equal(1, release_count)

    assert.are.equal(2, assert(collection:count_documents(filter, {
      limit = 5,
      skip = 1,
    })))
    local count_pipeline = commands[3].command:get("pipeline")

    assert.are.equal("$match", count_pipeline:get(1):keys()[1])
    assert.are.equal("$skip", count_pipeline:get(2):keys()[1])
    assert.are.equal("$limit", count_pipeline:get(3):keys()[1])
    assert.are.equal("$group", count_pipeline:get(4):keys()[1])
    assert.are.equal(3, assert(collection:estimated_document_count({ comment = "estimate" })))
    assert.are.equal("count", commands[4].command:keys()[1])

    local distinct = assert(collection:distinct("kind", filter, { hint = "kind_1" }))

    assert.are.same({ "a", "b" }, { distinct:get(1), distinct:get(2) })
    assert.are.equal("distinct", commands[5].command:keys()[1])
    assert.are.equal("kind_1", commands[5].command:get("hint"))

    local deleted = assert(collection:find_one_and_delete(filter, {
      projection = bson.document({ { "kind", 1 } }),
    }))
    local replaced = assert(collection:find_one_and_replace(
      filter,
      bson.document({ { "kind", "b" } }),
      { return_document = "after" }
    ))
    local updated = assert(collection:find_one_and_update(
      filter,
      bson.document({ { "$set", bson.document({ { "kind", "c" } }) } }),
      { return_document = "after" }
    ))

    assert.are.equal("a", deleted:get("kind"))
    assert.are.equal("b", replaced:get("kind"))
    assert.are.equal("c", updated:get("kind"))
    assert.is_true(commands[6].command:get("remove"))
    assert.are.equal("b", commands[7].command:get("update"):get("kind"))
    assert.is_true(commands[7].command:get("new"))
    assert.is_true(bson.is_document(commands[8].command:get("update"):get("$set")))
  end)

  it("handles empty counts, null modifications, and unacknowledged write pipelines", function()
    local response = bson.document({
      { "ok", 1 },
      { "cursor", bson.document({
        { "id", bson.int64(0) },
        { "ns", "app.users" },
        { "firstBatch", bson.array({}) },
      }) },
    })
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return { max_wire_version = 27 }
      end,
      command = function()
        local current = response

        response = bson.document({ { "ok", 1 }, { "value", bson.null } })
        return current
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("users"))

    assert.are.equal(0, assert(collection:count_documents(bson.document({}))))
    assert.is_nil(collection:find_one_and_delete(bson.document({})))

    local sent
    local unacknowledged_executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return { max_wire_version = 27 }
      end,
      command = function(_, _, command, options)
        sent = { command = command, options = options }
        return bson.document({ { "ok", 1 } })
      end,
    }
    local unacknowledged_config = assert(driver_options.normalize(nil, {
      write_concern = { w = 0 },
    }))
    local output = assert(api.new_client(unacknowledged_executor, unacknowledged_config)
      :database("app"):collection("users"):aggregate(bson.array({
        bson.document({ { "$out", "archive" } }),
      }), {
        batch_size = 2,
        bypass_document_validation = false,
        raw_data = true,
      }))

    assert.is_true(output:is_closed())
    assert.is_nil(sent.command:get("cursor"):get("batchSize"))
    assert.is_false(sent.command:get("bypassDocumentValidation"))
    assert.is_true(sent.command:get("rawData"))
    assert.are.equal(0, sent.command:get("writeConcern"):get("w"))
    assert.is_true(sent.options.no_response)
    assert.has_error(function()
      collection:find_one_and_update(
        bson.document({}),
        bson.document({ { "kind", "replacement" } })
      )
    end, "update document must begin with an atomic '$' modifier")
    assert.has_error(function()
      collection:find_one_and_replace(
        bson.document({}),
        bson.document({ { "$set", bson.document({ { "kind", "a" } }) } })
      )
    end, "replacement document must not begin with an atomic '$' modifier")
  end)
end)
