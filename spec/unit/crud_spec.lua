local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")

describe("single-document CRUD", function()
  it("generates insert ids, returns find results, and retains write error details", function()
    local generated_id = bson.object_id("010203041011121314151617")
    local commands = {}
    local response
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
        return response
      end,
    }
    local object_ids = {
      new = function()
        return generated_id
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      read_concern = { level = "majority" },
      write_concern = { w = "majority", w_timeout_ms = 500 },
    }))
    local client = api.new_client(executor, config, nil, nil, object_ids)
    local collection = assert(client:database("app"):collection("users"))
    local input = bson.document({ { "name", "Ada" } })

    response = bson.document({ { "ok", 1 }, { "n", 1 } })
    local inserted = assert(collection:insert_one(input, { comment = "unit" }))

    assert.is_true(inserted.acknowledged)
    assert.are.equal(generated_id, inserted.inserted_id)
    assert.is_nil(input:get("_id"))
    assert.are.equal("insert", commands[1].command:keys()[1])
    assert.are.equal("users", commands[1].command:get("insert"))
    assert.are.equal("unit", commands[1].command:get("comment"))
    assert.are.equal("majority", commands[1].command:get("writeConcern"):get("w"))
    assert.are.equal(500, commands[1].command:get("writeConcern"):get("wtimeout"))
    assert.is_nil(commands[1].command:get("writeConcern"):get("wtimeoutMS"))
    local encoded_document = commands[1].command:get("documents"):get(1)

    assert.are.equal("_id", encoded_document:keys()[1])
    assert.are.equal(generated_id, encoded_document:get("_id"))
    assert.has_error(function()
      inserted.acknowledged = false
    end, "CRUD results are immutable")

    local found = bson.document({ { "_id", generated_id }, { "name", "Ada" } })

    response = bson.document({
      { "ok", 1 },
      { "cursor", bson.document({
        { "id", bson.int64(0) },
        { "ns", "app.users" },
        { "firstBatch", bson.array({ found }) },
      }) },
    })
    assert.are.equal(found, assert(collection:find_one(
      bson.document({ { "name", "Ada" } }),
      { skip = 2, sort = bson.document({ { "name", 1 } }) }
    )))
    assert.are.equal("find", commands[2].command:keys()[1])
    assert.are.equal(1, commands[2].command:get("limit"))
    assert.is_true(commands[2].command:get("singleBatch"))
    assert.is_nil(commands[2].command:get("batchSize"))
    assert.are.equal(2, commands[2].command:get("skip"))

    local error_details = bson.document({ { "keyPattern", bson.document({ { "_id", 1 } }) } })

    response = bson.document({
      { "ok", 1 },
      { "writeErrors", bson.array({
        bson.document({
          { "index", 0 },
          { "code", 11000 },
          { "errmsg", "duplicate key" },
          { "errInfo", error_details },
        }),
      }) },
    })
    local duplicate_result, duplicate_err = collection:insert_one(
      bson.document({ { "_id", generated_id } })
    )

    assert.is_nil(duplicate_result)
    assert.is_true(errors.is(duplicate_err, errors.CATEGORY.WRITE))
    assert.are.equal(11000, duplicate_err.code)
    assert.are.equal("duplicate key", duplicate_err.message)
    assert.are.equal(error_details, duplicate_err.details.write_error)
  end)

  it("marks w=0 inserts unacknowledged and requests OP_MSG moreToCome", function()
    local command_options
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, _, options)
        command_options = options
        return bson.document({ { "ok", 1 } })
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      write_concern = { w = 0 },
    }))
    local client = api.new_client(executor, config)
    local collection = assert(client:database("app"):collection("events"))
    local inserted = assert(collection:insert_one(
      bson.document({ { "_id", 1 }, { "kind", "created" } })
    ))

    assert.is_false(inserted.acknowledged)
    assert.is_nil(inserted.inserted_id)
    assert.is_true(command_options.no_response)
  end)
end)
