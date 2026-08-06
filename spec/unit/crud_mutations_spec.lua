local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")

describe("update replace and delete CRUD", function()
  it("builds distinct mutation models and returns immutable result counts", function()
    local commands = {}
    local responses = {
      bson.document({ { "ok", 1 }, { "n", 1 }, { "nModified", 1 } }),
      bson.document({ { "ok", 1 }, { "n", 3 }, { "nModified", 2 } }),
      bson.document({
        { "ok", 1 },
        { "n", 1 },
        { "nModified", 0 },
        { "upserted", bson.array({
          bson.document({ { "index", 0 }, { "_id", 99 } }),
        }) },
      }),
      bson.document({ { "ok", 1 }, { "n", 1 } }),
      bson.document({ { "ok", 1 }, { "n", 4 } }),
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
        return table.remove(responses, 1)
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      write_concern = { w = "majority" },
    }))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("users"))
    local filter = bson.document({ { "active", true } })
    local update = bson.document({ { "$set", bson.document({ { "active", false } }) } })
    local one = assert(collection:update_one(filter, update, {
      array_filters = bson.array({
        bson.document({ { "item.active", true } }),
      }),
      bypass_document_validation = true,
      collation = bson.document({ { "locale", "en" } }),
      comment = "one",
      hint = "active_1",
      let = bson.document({ { "enabled", true } }),
      raw_data = true,
      sort = bson.document({ { "priority", -1 } }),
      upsert = true,
    }))

    assert.are.equal(1, one.matched_count)
    assert.are.equal(1, one.modified_count)
    assert.are.equal(0, one.upserted_count)
    assert.is_nil(one.upserted_id)
    local update_command = commands[1].command
    local update_model = update_command:get("updates"):get(1)

    assert.are.equal("update", update_command:keys()[1])
    assert.is_false(update_model:get("multi"))
    assert.is_true(update_model:get("upsert"))
    assert.are.equal("active_1", update_model:get("hint"))
    assert.are.equal("en", update_model:get("collation"):get("locale"))
    assert.are.equal(-1, update_model:get("sort"):get("priority"))
    assert.are.equal(true, update_command:get("bypassDocumentValidation"))
    assert.are.equal(true, update_command:get("rawData"))
    assert.are.equal(true, update_command:get("let"):get("enabled"))
    assert.are.equal("one", update_command:get("comment"))
    assert.are.equal("majority", update_command:get("writeConcern"):get("w"))

    local many = assert(collection:update_many(filter, bson.array({
      bson.document({ { "$set", bson.document({ { "active", false } }) } }),
    })))

    assert.are.equal(3, many.matched_count)
    assert.are.equal(2, many.modified_count)
    assert.is_true(commands[2].command:get("updates"):get(1):get("multi"))

    local replacement = bson.document({ { "name", "Ada" } })
    local replaced = assert(collection:replace_one(filter, replacement, { upsert = true }))

    assert.are.equal(0, replaced.matched_count)
    assert.are.equal(0, replaced.modified_count)
    assert.are.equal(1, replaced.upserted_count)
    assert.are.equal(99, replaced.upserted_id)
    assert.are.equal(replacement, commands[3].command:get("updates"):get(1):get("u"))
    assert.has_error(function()
      collection:update_one(filter, replacement)
    end, "update document must begin with an atomic '$' modifier")
    assert.has_error(function()
      collection:replace_one(filter, update)
    end, "replacement document must not begin with an atomic '$' modifier")

    local deleted_one = assert(collection:delete_one(filter))
    local deleted_many = assert(collection:delete_many(filter))

    assert.are.equal(1, deleted_one.deleted_count)
    assert.are.equal(4, deleted_many.deleted_count)
    assert.are.equal(1, commands[4].command:get("deletes"):get(1):get("limit"))
    assert.are.equal(0, commands[5].command:get("deletes"):get(1):get("limit"))
    assert.has_error(function()
      deleted_many.deleted_count = 0
    end, "CRUD results are immutable")
  end)

  it("uses moreToCome for supported unacknowledged mutations", function()
    local command_options = {}
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return { max_wire_version = 7 }
      end,
      command = function(_, _, _, options)
        command_options[#command_options + 1] = options
        return bson.document({ { "ok", 1 } })
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      write_concern = { w = 0 },
    }))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("events"))
    local filter = bson.document({ { "kind", "created" } })
    local update = bson.document({ { "$set", bson.document({ { "seen", true } }) } })
    local updated = assert(collection:update_one(filter, update))
    local deleted = assert(collection:delete_many(filter))

    assert.is_false(updated.acknowledged)
    assert.is_nil(updated.matched_count)
    assert.is_false(deleted.acknowledged)
    assert.is_nil(deleted.deleted_count)
    assert.is_true(command_options[1].no_response)
    assert.is_true(command_options[2].no_response)
    assert.has_error(function()
      collection:update_one(filter, update, {
        collation = bson.document({ { "locale", "en" } }),
      })
    end, "collation is unsupported for unacknowledged writes")
    assert.has_error(function()
      collection:update_one(filter, update, {
        array_filters = bson.array({ bson.document({ { "item", 1 } }) }),
      })
    end, "array_filters is unsupported for unacknowledged writes")
    assert.has_error(function()
      collection:update_one(filter, update, { hint = "kind_1" })
    end, "unacknowledged update hint requires MongoDB 4.2 or newer")
    assert.has_error(function()
      collection:delete_one(filter, { hint = "kind_1" })
    end, "unacknowledged delete hint requires MongoDB 4.4 or newer")
  end)
end)
