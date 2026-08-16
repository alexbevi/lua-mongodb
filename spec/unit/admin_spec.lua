local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")
local mongodb = require("mongodb")

local function config(options)
  return assert(driver_options.normalize(nil, options or {}))
end

local function cursor_response(namespace, id, documents, batch_name)
  return bson.document({
    { "ok", 1 },
    { "cursor", bson.document({
      { "id", bson.int64(id) },
      { "ns", namespace },
      { batch_name or "firstBatch", bson.array(documents) },
    }) },
  })
end

describe("database and collection management", function()
  it("creates an explicitly configured collection", function()
    local sent
    local executor = {
      close = function()
        return true
      end,
      command = function(_, database, command)
        sent = { command = command, database = database }
        return bson.document({ { "ok", 1 } })
      end,
    }
    local client = api.new_client(executor, config())
    local database = assert(client:database("app"))
    local collection = assert(database:create_collection("events", {
      capped = true,
      size = 4096,
    }))

    assert.are.equal("events", collection.name)
    assert.are.equal("app", sent.database)
    assert.are.equal("create", sent.command:keys()[1])
    assert.are.equal("events", sent.command:get("create"))
    assert.is_true(sent.command:get("capped"))
    assert.are.equal(4096, sent.command:get("size"))
  end)

  it("emits the server write concern timeout field", function()
    local command
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, value)
        command = value
        return bson.document({ { "ok", 1 } })
      end,
    }
    local database = assert(api.new_client(executor, config({
      write_concern = { w = "majority", w_timeout_ms = 500 },
    })):database("app"))

    assert.is_true(database:drop_collection("events"))

    local write_concern = command:get("writeConcern")

    assert.are.equal(500, write_concern:get("wtimeout"))
    assert.is_nil(write_concern:get("wtimeoutMS"))
  end)

  it("modifies collection validation and index constraints", function()
    local sent
    local executor = {
      close = function()
        return true
      end,
      command = function(_, database, command)
        sent = { command = command, database = database }
        return bson.document({ { "ok", 1 } })
      end,
    }
    local database = assert(api.new_client(executor, config({
      write_concern = { w = "majority" },
    })):database("app"))
    local response = assert(database:modify_collection("events", {
      index = bson.document({
        { "keyPattern", bson.document({ { "x", 1 } }) },
        { "prepareUnique", true },
      }),
      validator = bson.document({ { "x", bson.document({ { "$type", "string" } }) } }),
    }))

    assert.are.equal(1, response:get("ok"))
    assert.are.equal("app", sent.database)
    assert.are.equal("collMod", sent.command:keys()[1])
    assert.are.equal("events", sent.command:get("collMod"))
    assert.is_true(sent.command:get("index"):get("prepareUnique"))
    assert.are.equal("majority", sent.command:get("writeConcern"):get("w"))
  end)

  it("lists and drops databases and collections with command cursors", function()
    local commands = {}
    local responses = {
      bson.document({
        { "ok", 1 },
        { "databases", bson.array({
          bson.document({ { "name", "app" }, { "empty", false } }),
          bson.document({ { "name", "admin" }, { "empty", false } }),
        }) },
      }),
      cursor_response("app.$cmd.listCollections", 42, {
        bson.document({ { "name", "events" } }),
      }),
      cursor_response("app.$cmd.listCollections", 0, {
        bson.document({ { "name", "archive" } }),
      }, "nextBatch"),
      cursor_response("app.$cmd.listCollections", 0, {
        bson.document({ { "name", "events" } }),
      }),
      bson.document({ { "ok", 1 } }),
      bson.document({ { "ok", 1 } }),
    }
    local executor = {
      close = function()
        return true
      end,
      command = function(_, database, command)
        commands[#commands + 1] = { command = command, database = database }
        return table.remove(responses, 1)
      end,
    }
    local client = api.new_client(executor, config({
      write_concern = { w = "majority" },
    }))
    local databases = assert(client:list_database_names({
      authorized_databases = true,
      comment = "databases",
    }))

    assert.are.same({ "app", "admin" }, { databases[1], databases[2] })
    assert.are.equal("admin", commands[1].database)
    assert.is_true(commands[1].command:get("nameOnly"))
    assert.is_true(commands[1].command:get("authorizedDatabases"))

    local database = assert(client:database("app"))
    local cursor = assert(database:list_collections({
      batch_size = 1,
      comment = "collections",
    }))

    assert.are.equal("events", assert(cursor:next()):get("name"))
    assert.are.equal("archive", assert(cursor:next()):get("name"))
    assert.is_nil(cursor:next())
    assert.are.equal("getMore", commands[3].command:keys()[1])
    assert.are.equal("$cmd.listCollections", commands[3].command:get("collection"))
    assert.is_nil(commands[3].command:get("comment"))

    local names = assert(database:list_collection_names({
      filter = bson.document({ { "name", "events" } }),
    }))

    assert.are.equal("events", names[1])
    assert.is_true(commands[4].command:get("nameOnly"))
    assert.is_true(database:drop_collection("archive", { comment = "drop" }))
    assert.are.equal("drop", commands[5].command:keys()[1])
    assert.are.equal("majority", commands[5].command:get("writeConcern"):get("w"))
    assert.is_true(client:drop_database(database))
    assert.are.equal("dropDatabase", commands[6].command:keys()[1])
    assert.are.equal("app", commands[6].database)
  end)

  it("creates named index models and manages indexes", function()
    local commands = {}
    local responses = {
      bson.document({ { "ok", 1 } }),
      bson.document({ { "ok", 1 } }),
      bson.document({ { "ok", 1 } }),
      bson.document({ { "ok", 1 } }),
    }
    local executor = {
      capabilities = function()
        return { max_wire_version = 27 }
      end,
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command
        return table.remove(responses, 1)
      end,
    }
    local collection = assert(api.new_client(executor, config())
      :database("app"):collection("events"))
    local compound = mongodb.index_model(bson.document({
      { "kind", 1 },
      { "created_at", -1 },
    }), {
      partial_filter_expression = bson.document({ { "active", true } }),
      unique = true,
    })

    assert.are.equal("kind_1_created_at_-1", compound.name)
    assert.has_error(function()
      compound.name = "changed"
    end, "index models are immutable")

    local names = assert(collection:create_indexes({
      compound,
      mongodb.index_model(bson.document({ { "location", "2dsphere" } }), {
        name = "geo",
      }),
    }, {
      comment = "indexes",
      commit_quorum = "majority",
      raw_data = true,
    }))

    assert.are.same(
      { "kind_1_created_at_-1", "geo" },
      { names[1], names[2] }
    )
    local create = commands[1]
    assert.are.equal("createIndexes", create:keys()[1])
    assert.are.equal("majority", create:get("commitQuorum"))
    assert.is_true(create:get("rawData"))
    assert.are.equal(2, #create:get("indexes"))
    assert.is_true(create:get("indexes"):get(1):get("unique"))
    assert.are.equal(
      "kind_1_created_at_-1",
      create:get("indexes"):get(1):get("name")
    )

    assert.are.equal(
      "score_-1",
      assert(collection:create_index(bson.document({ { "score", -1 } }), {
        sparse = true,
      }))
    )
    assert.is_true(collection:drop_index(compound))
    assert.are.equal("kind_1_created_at_-1", commands[3]:get("index"))
    assert.is_true(collection:drop_indexes())
    assert.are.equal("*", commands[4]:get("index"))
    assert.has_error(function()
      collection:drop_index("*")
    end, "drop_index cannot drop all indexes; use drop_indexes")
    assert.has_error(function()
      mongodb.index_model(bson.document({ { "x", 0 } }))
    end, "index direction must be 1, -1, or a supported index type")
  end)

  it("creates one Search index and returns its server name", function()
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, value)
        commands[#commands + 1] = value
        local model = value:get("indexes"):get(1)

        return bson.document({
          { "ok", 1 },
          { "indexesCreated", bson.array({
            bson.document({ { "name", model:get("name") or "default" } }),
          }) },
        })
      end,
    }
    local collection = assert(api.new_client(executor, config())
      :database("app"):collection("events"))
    local definition = bson.document({
      { "mappings", bson.document({ { "dynamic", true } }) },
    })

    assert.are.equal("default", assert(collection:create_search_index(
      bson.document({
        { "definition", definition },
        { "type", "search" },
      })
    )))
    local command = commands[1]

    assert.are.equal("createSearchIndexes", command:keys()[1])
    assert.are.equal("events", command:get("createSearchIndexes"))
    assert.are.equal(
      definition,
      command:get("indexes"):get(1):get("definition")
    )
    assert.are.equal("search", command:get("indexes"):get(1):get("type"))
    assert.are.equal("default", assert(collection:create_search_index(
      bson.document({ { "definition", definition } })
    )))
    assert.is_nil(commands[2]:get("indexes"):get(1):get("type"))

    local vector_definition = bson.document({
      { "fields", bson.array({
        bson.document({
          { "type", "vector" },
          { "path", "embedding" },
          { "numDimensions", 3 },
          { "similarity", "euclidean" },
        }),
      }) },
    })

    assert.are.equal("vectors", assert(collection:create_search_index(
      bson.document({
        { "definition", vector_definition },
        { "name", "vectors" },
        { "type", "vectorSearch" },
      })
    )))
    local vector_model = commands[3]:get("indexes"):get(1)

    assert.are.equal(vector_definition, vector_model:get("definition"))
    assert.are.equal("vectors", vector_model:get("name"))
    assert.are.equal("vectorSearch", vector_model:get("type"))
  end)

  it("validates Search index models and propagates command failures", function()
    local calls = 0
    local failure = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "Atlas Search is unavailable",
    })
    local executor = {
      close = function()
        return true
      end,
      command = function()
        calls = calls + 1

        if calls == 1 then
          return nil, failure
        end

        return bson.document({
          { "ok", 1 },
          { "indexesCreated", bson.array({}) },
        })
      end,
    }
    local collection = assert(api.new_client(executor, config())
      :database("app"):collection("events"))
    local model = bson.document({
      { "definition", bson.document({ { "mappings", bson.document({}) } }) },
    })
    local name, err = collection:create_search_index(model)

    assert.is_nil(name)
    assert.are.equal(failure, err)
    name, err = collection:create_search_index(model)
    assert.is_nil(name)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
    assert.has_error(function()
      collection:create_search_index(bson.document({}))
    end, "search index definition must be a BSON document")
    assert.has_error(function()
      collection:create_search_index(bson.document({
        { "definition", bson.document({}) },
        { "name", "" },
      }))
    end, "search index name must be a non-empty UTF-8 string without null bytes")
    assert.has_error(function()
      collection:create_search_index(bson.document({
        { "definition", bson.document({}) },
        { "type", "vector" },
      }))
    end, "search index type must be search or vectorSearch")
    assert.has_error(function()
      collection:create_search_index(bson.document({
        { "definition", bson.document({}) },
        { "extra", true },
      }))
    end, "unknown search index model field: extra")
    assert.are.equal(2, calls)
  end)

  it("creates multiple Search indexes in model order", function()
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, value)
        commands[#commands + 1] = value
        local created = {}

        if #value:get("indexes") > 0 then
          created = {
            bson.document({ { "name", "standard" } }),
            bson.document({ { "name", "vectors" } }),
          }
        end

        return bson.document({
          { "ok", 1 },
          { "indexesCreated", bson.array(created) },
        })
      end,
    }
    local collection = assert(api.new_client(executor, config())
      :database("app"):collection("events"))
    local names = assert(collection:create_search_indexes({
      bson.document({
        { "definition", bson.document({
          { "mappings", bson.document({ { "dynamic", true } }) },
        }) },
        { "name", "standard" },
        { "type", "search" },
      }),
      bson.document({
        { "definition", bson.document({
          { "fields", bson.array({
            bson.document({
              { "type", "vector" },
              { "path", "embedding" },
              { "numDimensions", 3 },
              { "similarity", "euclidean" },
            }),
          }) },
        }) },
        { "name", "vectors" },
        { "type", "vectorSearch" },
      }),
    }))

    assert.are.same({ "standard", "vectors" }, { names[1], names[2] })
    local command = commands[1]

    assert.are.equal("standard", command:get("indexes"):get(1):get("name"))
    assert.are.equal("vectors", command:get("indexes"):get(2):get("name"))
    assert.has_error(function()
      names[1] = "changed"
    end, "administration results are immutable")
    local empty = assert(collection:create_search_indexes({}))

    assert.are.equal(0, #empty)
    assert.are.equal(0, #commands[2]:get("indexes"))
    assert.has_error(function()
      collection:create_search_indexes("models")
    end, "search indexes must be a dense array")
    assert.has_error(function()
      collection:create_search_indexes({ [2] = bson.document({}) })
    end, "search indexes must be a dense array")
    assert.are.equal(2, #commands)
  end)

  it("lists Search indexes through aggregation without concerns", function()
    local commands = {}
    local executions = {}
    local responses = {
      cursor_response("app.events", 0, {
        bson.document({ { "name", "standard" } }),
      }),
      cursor_response("app.events", 0, {
        bson.document({ { "name", "vectors" } }),
      }),
    }
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command, options)
        commands[#commands + 1] = command
        executions[#executions + 1] = options
        return table.remove(responses, 1)
      end,
    }
    local collection = assert(api.new_client(executor, config({
      read_concern = { level = "majority" },
      write_concern = { w = "majority" },
    })):database("app"):collection("events"))
    local all = assert(collection:list_search_indexes())

    assert.are.equal("standard", assert(all:next()):get("name"))
    local list_all = commands[1]
    local all_stage = list_all:get("pipeline"):get(1):get("$listSearchIndexes")

    assert.are.equal("aggregate", list_all:keys()[1])
    assert.are.equal(0, #all_stage)
    assert.is_nil(list_all:get("readConcern"))
    assert.is_nil(list_all:get("writeConcern"))
    assert.are.equal("primary", executions[1].read_preference.mode)

    local named = assert(collection:list_search_indexes("vectors", {
      batch_size = 10,
    }))

    assert.are.equal("vectors", assert(named:next()):get("name"))
    local list_named = commands[2]
    local named_stage = list_named:get("pipeline"):get(1):get("$listSearchIndexes")

    assert.are.equal("vectors", named_stage:get("name"))
    assert.are.equal(10, list_named:get("cursor"):get("batchSize"))
    assert.is_nil(list_named:get("readConcern"))
    assert.is_nil(list_named:get("writeConcern"))
  end)

  it("updates a Search index definition", function()
    local commands = {}
    local failure = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "Atlas Search is unavailable",
    })
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command

        if #commands == 2 then
          return nil, failure
        end

        return bson.document({ { "ok", 1 } })
      end,
    }
    local collection = assert(api.new_client(executor, config())
      :database("app"):collection("events"))
    local definition = bson.document({
      { "mappings", bson.document({ { "dynamic", false } }) },
    })

    assert.is_true(collection:update_search_index("standard", definition))
    local command = commands[1]

    assert.are.equal("updateSearchIndex", command:keys()[1])
    assert.are.equal("events", command:get("updateSearchIndex"))
    assert.are.equal("standard", command:get("name"))
    assert.are.equal(definition, command:get("definition"))
    local updated, err = collection:update_search_index("standard", definition)

    assert.is_nil(updated)
    assert.are.equal(failure, err)
    assert.has_error(function()
      collection:update_search_index("", definition)
    end, "search index name must be a non-empty UTF-8 string without null bytes")
    assert.has_error(function()
      collection:update_search_index("standard", {})
    end, "search index definition must be a BSON document")
    assert.are.equal(2, #commands)
  end)

  it("drops a Search index idempotently", function()
    local commands = {}
    local missing = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 26,
      message = "namespace not found",
    })
    local failure = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 13,
      message = "not authorized",
    })
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command

        if #commands == 2 then
          return nil, missing
        elseif #commands == 3 then
          return nil, failure
        end

        return bson.document({ { "ok", 1 } })
      end,
    }
    local collection = assert(api.new_client(executor, config())
      :database("app"):collection("events"))

    assert.is_true(collection:drop_search_index("standard"))
    assert.are.equal("dropSearchIndex", commands[1]:keys()[1])
    assert.are.equal("events", commands[1]:get("dropSearchIndex"))
    assert.are.equal("standard", commands[1]:get("name"))
    assert.is_true(collection:drop_search_index("standard"))
    local dropped, err = collection:drop_search_index("standard")

    assert.is_nil(dropped)
    assert.are.equal(failure, err)
    assert.has_error(function()
      collection:drop_search_index(1)
    end, "search index name must be a non-empty UTF-8 string without null bytes")
    assert.are.equal(3, #commands)
  end)

  it("lists indexes and inherits comments on getMore", function()
    local commands = {}
    local responses = {
      cursor_response("app.events", 91, {
        bson.document({ { "name", "_id_" } }),
      }),
      cursor_response("app.events", 0, {
        bson.document({ { "name", "kind_1" } }),
      }, "nextBatch"),
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
    local collection = assert(api.new_client(executor, config())
      :database("app"):collection("events"))
    local cursor = assert(collection:list_indexes({
      batch_size = 1,
      comment = "index-list",
    }))

    assert.are.equal("_id_", assert(cursor:next()):get("name"))
    assert.are.equal("kind_1", assert(cursor:next()):get("name"))
    assert.are.equal("events", commands[2]:get("collection"))
    assert.are.equal("index-list", commands[2]:get("comment"))
  end)

  it("retains write concern errors and validates wire-version options", function()
    local executor = {
      capabilities = function()
        return { max_wire_version = 8 }
      end,
      close = function()
        return true
      end,
      command = function()
        return bson.document({
          { "ok", 1 },
          { "writeConcernError", bson.document({
            { "code", 64 },
            { "errmsg", "write concern timed out" },
          }) },
        })
      end,
    }
    local collection = assert(api.new_client(executor, config())
      :database("app"):collection("events"))

    assert.has_error(function()
      collection:create_index(bson.document({ { "x", 1 } }), {
        commit_quorum = 1,
      })
    end, "commit_quorum requires MongoDB 4.4 or newer")

    local created, err = collection:create_index(bson.document({ { "x", 1 } }))

    assert.is_nil(created)
    assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
    assert.are.equal(64, err.code)
    assert.is_true(bson.is_document(err.details.response))
  end)
end)
