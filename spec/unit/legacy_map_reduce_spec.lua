local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")

describe("legacy collection map reduce", function()
  it("encodes inline output and returns its results", function()
    local sent
    local results = bson.array({
      bson.document({ { "_id", 0 }, { "value", 35 } }),
    })
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return { max_wire_version = 21 }
      end,
      command = function(_, database, command, options)
        sent = {
          command = command,
          database = database,
          options = options,
        }
        return bson.document({ { "ok", 1 }, { "results", results } })
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      read_concern = { level = "majority" },
      write_concern = {},
    }))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("users"))
    local map = bson.code("function () { emit(0, this.x); }")
    local reduce = bson.code("function (key, values) { return values[0]; }")
    local out = bson.document({ { "inline", 1 } })
    local filter = bson.document({ { "kind", "active" } })
    local collation = bson.document({ { "locale", "en" } })
    local finalize = bson.code("function (key, value) { return value; }")
    local scope = bson.document({ { "offset", 1 } })
    local sort = bson.document({ { "x", 1 } })

    assert.are.equal(results, assert(collection:map_reduce(map, reduce, out, {
      bypass_document_validation = false,
      collation = collation,
      comment = "legacy map reduce",
      finalize = finalize,
      js_mode = true,
      limit = 2,
      max_time_ms = 50,
      query = filter,
      scope = scope,
      sort = sort,
      verbose = false,
    })))
    assert.are.equal("app", sent.database)
    assert.are.equal("mapReduce", sent.command:keys()[1])
    assert.are.equal("users", sent.command:get("mapReduce"))
    assert.are.equal(map, sent.command:get("map"))
    assert.are.equal(reduce, sent.command:get("reduce"))
    assert.are.equal(out, sent.command:get("out"))
    assert.is_false(sent.command:get("bypassDocumentValidation"))
    assert.are.equal(collation, sent.command:get("collation"))
    assert.are.equal("legacy map reduce", sent.command:get("comment"))
    assert.are.equal(finalize, sent.command:get("finalize"))
    assert.is_true(sent.command:get("jsMode"))
    assert.are.equal(2, sent.command:get("limit"))
    assert.are.equal(50, sent.command:get("maxTimeMS"))
    assert.are.equal(filter, sent.command:get("query"))
    assert.are.equal(scope, sent.command:get("scope"))
    assert.are.equal(sort, sent.command:get("sort"))
    assert.is_false(sent.command:get("verbose"))
    assert.are.equal("majority", sent.command:get("readConcern"):get("level"))
    assert.is_nil(sent.command:get("writeConcern"))
  end)

  it("applies inherited concern only to collection output", function()
    local sent
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return { max_wire_version = 21 }
      end,
      command = function(_, _, command, options)
        sent = { command = command, options = options }
        return bson.document({ { "ok", 1 }, { "result", "summary" } })
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      read_concern = { level = "majority" },
      write_concern = { w = 2 },
    }))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("users"))

    assert.are.equal("summary", assert(collection:map_reduce(
      "function () { emit(0, this.x); }",
      "function (key, values) { return values[0]; }",
      "summary"
    )))
    assert.are.equal(2, sent.command:get("writeConcern"):get("w"))
    assert.is_nil(sent.command:get("readConcern"))
    assert.is_false(sent.options.read_operation)
  end)
end)
