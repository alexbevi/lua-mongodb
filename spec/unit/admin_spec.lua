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
