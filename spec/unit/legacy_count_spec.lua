local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")

describe("legacy collection count", function()
  it("encodes the count command and returns n", function()
    local sent
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return { max_wire_version = 27 }
      end,
      command = function(_, database, command, options)
        sent = {
          command = command,
          database = database,
          options = options,
        }
        return bson.document({ { "ok", 1 }, { "n", bson.int64(2) } })
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      read_concern = { level = "majority" },
    }))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("users"))
    local filter = bson.document({ { "kind", "active" } })
    local collation = bson.document({ { "locale", "en" } })

    assert.are.equal(2, assert(collection:count(filter, {
      collation = collation,
      comment = "legacy count",
      hint = "kind_1",
      limit = 3,
      max_time_ms = 50,
      raw_data = true,
      skip = 1,
    })))
    assert.are.equal("app", sent.database)
    assert.are.equal("count", sent.command:keys()[1])
    assert.are.equal("users", sent.command:get("count"))
    assert.are.equal(filter, sent.command:get("query"))
    assert.are.equal(collation, sent.command:get("collation"))
    assert.are.equal("legacy count", sent.command:get("comment"))
    assert.are.equal("kind_1", sent.command:get("hint"))
    assert.are.equal(3, sent.command:get("limit"))
    assert.are.equal(50, sent.command:get("maxTimeMS"))
    assert.is_true(sent.command:get("rawData"))
    assert.are.equal(1, sent.command:get("skip"))
    assert.are.equal("majority", sent.command:get("readConcern"):get("level"))
  end)
end)
