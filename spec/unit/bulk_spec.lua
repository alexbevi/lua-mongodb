local api = require("mongodb.api")
local bson = require("mongodb.bson")
local bulk = require("mongodb.bulk")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")

describe("collection bulk writes", function()
  it("batches insert_many at maxWriteBatchSize and preserves generated ids", function()
    local commands = {}
    local next_id = 0
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 1024,
          max_message_size = 4096,
          max_wire_version = 27,
          max_write_batch_size = 2,
        }
      end,
      command = function(_, database, command, options)
        commands[#commands + 1] = {
          command = command,
          database = database,
          options = options,
        }
        return bson.document({
          { "ok", 1 },
          { "n", #options.sequences[1].documents },
        })
      end,
    }
    local object_ids = {
      new = function()
        next_id = next_id + 1
        return bson.object_id(string.format("%024x", next_id))
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      write_concern = { w = "majority" },
    }))
    local collection = assert(api.new_client(executor, config, nil, nil, object_ids)
      :database("app"):collection("events"))
    local documents = {
      bson.document({ { "kind", "a" } }),
      bson.document({ { "_id", 40 }, { "kind", "b" } }),
      bson.document({ { "kind", "c" } }),
    }
    local inserted = assert(collection:insert_many(documents, {
      comment = "batch",
      ordered = true,
    }))

    assert.is_true(inserted.acknowledged)
    assert.are.equal(3, #inserted.inserted_ids)
    assert.are.equal(bson.object_id("000000000000000000000001"), inserted.inserted_ids[1])
    assert.are.equal(40, inserted.inserted_ids[2])
    assert.are.equal(bson.object_id("000000000000000000000002"), inserted.inserted_ids[3])
    assert.is_nil(documents[1]:get("_id"))
    assert.are.equal(2, #commands)
    assert.are.equal("insert", commands[1].command:keys()[1])
    assert.is_true(commands[1].command:get("ordered"))
    assert.are.equal("batch", commands[1].command:get("comment"))
    assert.are.equal("documents", commands[1].options.sequences[1].identifier)
    assert.are.equal(2, #commands[1].options.sequences[1].documents)
    assert.are.equal(1, #commands[2].options.sequences[1].documents)
    assert.has_error(function()
      inserted.inserted_ids[1] = 50
    end, "bulk result values are immutable")
  end)

  it("emits the server write concern timeout field", function()
    local command
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 1024,
          max_message_size = 4096,
          max_wire_version = 27,
          max_write_batch_size = 1000,
        }
      end,
      command = function(_, _, value)
        command = value
        return bson.document({ { "ok", 1 }, { "n", 1 } })
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      write_concern = { w = "majority", w_timeout_ms = 500 },
    }))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("events"))

    assert(collection:insert_many({ bson.document({ { "_id", 1 } }) }))

    local write_concern = command:get("writeConcern")

    assert.are.equal(500, write_concern:get("wtimeout"))
    assert.is_nil(write_concern:get("wtimeoutMS"))
  end)

  it("preserves ordered runs and merges counts and upsert indexes", function()
    local commands = {}
    local responses = {
      bson.document({ { "ok", 1 }, { "n", 1 } }),
      bson.document({
        { "ok", 1 },
        { "n", 2 },
        { "nModified", 1 },
        { "upserted", bson.array({
          bson.document({ { "index", 1 }, { "_id", 99 } }),
        }) },
      }),
      bson.document({ { "ok", 1 }, { "n", 1 } }),
      bson.document({ { "ok", 1 }, { "n", 1 } }),
    }
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 1024,
          max_message_size = 4096,
          max_wire_version = 27,
          max_write_batch_size = 2,
        }
      end,
      command = function(_, _, command, options)
        commands[#commands + 1] = { command = command, options = options }
        return table.remove(responses, 1)
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      write_concern = { w = "majority" },
    }))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("events"))
    local filter = bson.document({ { "kind", "a" } })
    local update = bson.document({ { "$set", bson.document({ { "seen", true } }) } })
    local written = assert(collection:bulk_write({
      bulk.insert_one(bson.document({ { "_id", 1 } })),
      bulk.update_one(filter, update),
      bulk.update_one(filter, update, { upsert = true }),
      bulk.delete_one(filter),
      bulk.insert_one(bson.document({ { "_id", 5 } })),
    }, {
      comment = "mixed",
      let = bson.document({ { "enabled", true } }),
      ordered = true,
    }))

    assert.are.equal(2, written.inserted_count)
    assert.are.equal(1, written.matched_count)
    assert.are.equal(1, written.modified_count)
    assert.are.equal(1, written.deleted_count)
    assert.are.equal(1, written.upserted_count)
    assert.are.equal(99, written.upserted_ids[3])
    assert.are.same(
      { "insert", "update", "delete", "insert" },
      {
        commands[1].command:keys()[1],
        commands[2].command:keys()[1],
        commands[3].command:keys()[1],
        commands[4].command:keys()[1],
      }
    )
    assert.is_nil(commands[1].command:get("let"))
    assert.is_true(bson.is_document(commands[2].command:get("let")))
    assert.is_true(bson.is_document(commands[3].command:get("let")))
    assert.are.equal(2, #commands[2].options.sequences[1].documents)

    for index = 2, #commands do
      assert.are.equal(
        commands[1].options.operation_id,
        commands[index].options.operation_id
      )
    end
  end)

  it("continues unordered runs and remaps write errors to original indexes", function()
    local commands = {}
    local responses = {
      bson.document({
        { "ok", 1 },
        { "n", 1 },
        { "writeErrors", bson.array({
          bson.document({
            { "index", 1 },
            { "code", 11000 },
            { "codeName", "DuplicateKey" },
            { "errmsg", "duplicate key" },
          }),
        }) },
      }),
      bson.document({ { "ok", 1 }, { "n", 1 } }),
      bson.document({ { "ok", 1 }, { "n", 1 }, { "nModified", 1 } }),
      bson.document({ { "ok", 1 }, { "n", 1 } }),
    }
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 1024,
          max_message_size = 4096,
          max_wire_version = 27,
          max_write_batch_size = 2,
        }
      end,
      command = function(_, _, command, options)
        commands[#commands + 1] = { command = command, options = options }
        return table.remove(responses, 1)
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("events"))
    local filter = bson.document({ { "kind", "a" } })
    local written, err = collection:bulk_write({
      bulk.insert_one(bson.document({ { "_id", 1 } })),
      bulk.delete_one(filter),
      bulk.insert_one(bson.document({ { "_id", 3 } })),
      bulk.update_one(filter, bson.document({
        { "$set", bson.document({ { "seen", true } }) },
      })),
      bulk.insert_one(bson.document({ { "_id", 5 } })),
    }, { ordered = false })

    assert.is_nil(written)
    assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
    assert.are.equal(11000, err.code)
    assert.are.equal("DuplicateKey", err.code_name)
    assert.are.equal(3, err.details.write_errors[1].index)
    assert.are.equal(2, err.details.partial_result.inserted_count)
    assert.are.equal(1, err.details.partial_result.matched_count)
    assert.are.equal(1, err.details.partial_result.deleted_count)
    assert.are.equal(5, err.details.processed_count)
    assert.are.same(
      { "insert", "insert", "update", "delete" },
      {
        commands[1].command:keys()[1],
        commands[2].command:keys()[1],
        commands[3].command:keys()[1],
        commands[4].command:keys()[1],
      }
    )
  end)

  it("continues after write concern errors and returns the full partial result", function()
    local commands = 0
    local responses = {
      bson.document({
        { "ok", 1 },
        { "n", 1 },
        { "writeConcernError", bson.document({
          { "code", 64 },
          { "errmsg", "waiting for replication timed out" },
          { "errInfo", bson.document({ { "wtimeout", true } }) },
        }) },
      }),
      bson.document({ { "ok", 1 }, { "n", 1 } }),
    }
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 1024,
          max_message_size = 4096,
          max_wire_version = 27,
          max_write_batch_size = 1,
        }
      end,
      command = function()
        commands = commands + 1
        return table.remove(responses, 1)
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      write_concern = { w = "majority" },
    }))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("events"))
    local written, err = collection:insert_many({
      bson.document({ { "_id", 1 } }),
      bson.document({ { "_id", 2 } }),
    })

    assert.is_nil(written)
    assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
    assert.are.equal(64, err.code)
    assert.are.equal(2, commands)
    assert.are.equal(2, err.details.partial_result.inserted_count)
    assert.is_true(err.details.write_concern_errors[1].details:get("wtimeout"))
  end)

  it("preserves ordered semantics for unacknowledged batches", function()
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 1024,
          max_message_size = 4096,
          max_wire_version = 7,
          max_write_batch_size = 2,
        }
      end,
      command = function(_, _, command, options)
        commands[#commands + 1] = { command = command, options = options }
        return bson.document({
          { "ok", 1 },
          { "n", #options.sequences[1].documents },
        })
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      write_concern = { w = 0 },
    }))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("events"))
    local inserted = assert(collection:insert_many({
      bson.document({ { "_id", 1 } }),
      bson.document({ { "_id", 2 } }),
      bson.document({ { "_id", 3 } }),
    }))

    assert.is_false(inserted.acknowledged)
    assert.is_nil(inserted.inserted_ids)
    assert.is_nil(inserted.inserted_count)
    assert.are.equal(2, #commands)
    assert.is_false(commands[1].options.no_response)
    assert.is_nil(commands[1].command:get("writeConcern"))
    assert.is_true(commands[2].options.no_response)
    assert.are.equal(0, commands[2].command:get("writeConcern"):get("w"))

    local filter = bson.document({})

    assert.has_error(function()
      collection:bulk_write({
        bulk.delete_one(filter, {
          collation = bson.document({ { "locale", "en" } }),
        }),
      })
    end, "collation is unsupported for unacknowledged writes")
    assert.has_error(function()
      collection:bulk_write({
        bulk.update_one(filter, bson.document({
          { "$set", bson.document({ { "seen", true } }) },
        }), { hint = "seen_1" }),
      })
    end, "unacknowledged update hint requires MongoDB 4.2 or newer")
    assert.has_error(function()
      collection:insert_many({ bson.document({ { "_id", 4 } }) }, {
        bypass_document_validation = true,
      })
    end, "bypass_document_validation is unsupported for unacknowledged writes")
  end)

  it("stops ordered execution after the first write error", function()
    local commands = 0
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 1024,
          max_message_size = 4096,
          max_wire_version = 27,
          max_write_batch_size = 1,
        }
      end,
      command = function()
        commands = commands + 1
        return bson.document({
          { "ok", 1 },
          { "n", 0 },
          { "writeErrors", bson.array({
            bson.document({
              { "index", 0 },
              { "code", 121 },
              { "errmsg", "validation failed" },
            }),
          }) },
        })
      end,
    }
    local collection = assert(api.new_client(
      executor,
      assert(driver_options.normalize(nil, {}))
    ):database("app"):collection("events"))
    local written, err = collection:insert_many({
      bson.document({ { "_id", 1 } }),
      bson.document({ { "_id", 2 } }),
    })

    assert.is_nil(written)
    assert.are.equal(1, commands)
    assert.are.equal(1, err.details.write_errors[1].index)
    assert.are.equal(1, err.details.processed_count)
    assert.are.equal(1, err.details.unprocessed_count)
  end)

  it("preserves command errors through the bulk error boundary", function()
    local response = bson.document({
      { "ok", 0 },
      { "code", 8 },
      { "codeName", "UnknownError" },
      { "errmsg", "failpoint error" },
    })
    local command_error = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 8,
      code_name = "UnknownError",
      details = { response = response },
      labels = { "RetryableWriteError" },
      message = "failpoint error",
    })
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 1024,
          max_message_size = 4096,
          max_wire_version = 27,
          max_write_batch_size = 1000,
        }
      end,
      command = function()
        return nil, command_error
      end,
    }
    local collection = assert(api.new_client(
      executor,
      assert(driver_options.normalize(nil, {}))
    ):database("app"):collection("events"))
    local written, err = collection:bulk_write({
      bulk.insert_one(bson.document({ { "_id", 1 } })),
    })

    assert.is_nil(written)
    assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
    assert.are.equal(8, err.code)
    assert.are.equal("UnknownError", err.code_name)
    assert.are.equal(response, err.details.response)
    assert.is_true(err:has_label("RetryableWriteError"))
  end)
end)
