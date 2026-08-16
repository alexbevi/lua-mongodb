local api = require("mongodb.api")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local driver_options = require("mongodb.config.options")
local fake_runtime = require("mongodb.runtime.fake")

describe("core MongoDB handles", function()
  it("uses supplied capabilities without application discovery", function()
    local discovery_calls = 0
    local executor = {
      capabilities = function()
        discovery_calls = discovery_calls + 1
        return {
          max_bson_size = 1,
          max_message_size = 1,
          max_wire_version = 1,
          max_write_batch_size = 1,
        }
      end,
      close = function() return true end,
      command = function()
        return bson.document({ { "ok", 1 } })
      end,
    }
    local capabilities = {
      max_bson_size = 16 * 1024 * 1024,
      max_message_size = 48000000,
      max_wire_version = 25,
      max_write_batch_size = 100000,
    }
    local client = api.new_client(
      executor,
      assert(driver_options.normalize()),
      nil,
      nil,
      nil,
      nil,
      nil,
      nil,
      capabilities
    )

    assert.are.equal(0, discovery_calls)
    assert(client:database("db"))
  end)

  it("validates immutable namespaces, inherits options, runs commands, and closes", function()
    local calls = {}
    local executor = {
      close = function(self)
        self.closed = true
        return true
      end,
      command = function(_, database, command, options)
        calls[#calls + 1] = { database = database, command = command, options = options }
        return bson.document({ { "ok", 1 }, { "database", database } })
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      read_concern = { level = "majority" },
      read_preference = { mode = "secondary_preferred" },
      write_concern = { w = "majority" },
    }))
    local client = api.new_client(executor, config, "app", { "ignored URI option" })
    local database = assert(client:database(nil, {
      read_preference = { mode = "primary" },
    }))
    local collection = assert(database:collection("users"))

    assert.are.equal("app", database.name)
    assert.are.equal("users", collection.name)
    assert.are.equal("app.users", collection.full_name)
    assert.are.equal("majority", collection.read_concern.level)
    assert.are.equal("primary", collection.read_preference.mode)
    assert.are.equal("majority", collection.write_concern.w)
    assert.has_error(function()
      collection.name = "renamed"
    end, "MongoDB collection handles are immutable")
    assert.has_error(function()
      client.warnings[1] = "changed"
    end, "MongoDB client handles are immutable")
    assert.has_error(function()
      client:database("bad name")
    end, "database name contains a prohibited character")
    assert.has_error(function()
      database:collection("bad..name")
    end, "collection name cannot be empty or contain '..'")

    local reply = assert(database:run_command(bson.document({ { "ping", 1 } })))

    assert.are.equal("app", reply:get("database"))
    assert.are.equal("app", calls[1].database)
    assert.are.equal("ping", calls[1].command:keys()[1])
    assert.is_true(client:close())
    assert.is_false(client:close())
    assert.is_true(executor.closed)

    local closed_reply, closed_err = database:run_command("ping")

    assert.is_nil(closed_reply)
    assert.is_true(errors.is(closed_err, errors.CATEGORY.CLIENT))
    assert.are.equal("client is closed", closed_err.message)
  end)

  it("derives one operation deadline from the inherited timeout", function()
    local received
    local executor = {
      close = function() return true end,
      command = function(_, _, _, options)
        received = options
        return bson.document({ { "ok", 1 } })
      end,
    }
    local config = assert(driver_options.normalize(nil, { timeout_ms = 50 }))
    local runtime = fake_runtime.new({ now = 10 })
    local client = api.new_client(
      executor,
      config,
      nil,
      nil,
      nil,
      nil,
      runtime
    )

    assert(client:database("db"):run_command("ping"))
    assert.near(10.05, received.deadline, 0.000001)
  end)

  it("defaults generic command selection to primary", function()
    local received
    local executor = {
      close = function() return true end,
      command = function(_, _, _, options)
        received = options
        return bson.document({ { "ok", 1 } })
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      read_preference = { mode = "secondary" },
    }))
    local client = api.new_client(executor, config)

    assert(client:database("db"):run_command("ping"))
    assert.is_true(received.read_operation)
    assert.are.equal("primary", received.read_preference.mode)
  end)

  it("executes a generic command cursor on its selected server", function()
    local calls = {}
    local released_sessions = 0
    local executor = {
      close = function() return true end,
      command = function(_, database, command, options)
        calls[#calls + 1] = {
          command = command,
          database = database,
          options = options,
        }

        if command:get("getMore") == nil then
          options.on_server_selected("server:27017")
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(42) },
              { "ns", "db.items" },
              { "firstBatch", bson.array({
                bson.document({ { "_id", 1 } }),
              }) },
            }) },
          })
        end

        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "db.items" },
            { "nextBatch", bson.array({
              bson.document({ { "_id", 2 } }),
            }) },
          }) },
        })
      end,
      release_session_context = function(_, context)
        assert.is_table(context)
        released_sessions = released_sessions + 1
      end,
    }
    local config = assert(driver_options.normalize())
    local client = api.new_client(executor, config)
    local comment = bson.document({ { "source", "test" } })
    local cursor = assert(client:database("db"):run_cursor_command(
      bson.document({ { "find", "items" }, { "batchSize", 1 } }),
      {
        batch_size = 5,
        comment = comment,
        max_await_time_ms = 300,
      }
    ))

    assert.are.equal(1, assert(cursor:next()):get("_id"))
    assert.are.equal(2, assert(cursor:next()):get("_id"))
    assert.are.equal(1, released_sessions)
    assert.is_nil(cursor:next())
    assert.are.equal("db", calls[1].database)
    assert.are.equal("find", calls[1].command:keys()[1])
    assert.are.equal("server:27017", calls[2].options.server_address)
    assert.are.equal(5, calls[2].command:get("batchSize"))
    assert.are.equal(300, calls[2].command:get("maxTimeMS"))
    assert.are.equal(comment, calls[2].command:get("comment"))
  end)

  it("rejects incompatible generic command cursor timeout options", function()
    local calls = 0
    local executor = {
      close = function() return true end,
      command = function()
        calls = calls + 1
        error("command execution must not be reached")
      end,
    }
    local config = assert(driver_options.normalize())
    local database = api.new_client(executor, config):database("db")
    local command = bson.document({ { "find", "items" } })
    local cursor, err = database:run_cursor_command(command, {
      timeout_mode = "cursor_lifetime",
    })

    assert.is_nil(cursor)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal("timeout_mode requires timeout_ms", err.message)

    cursor, err = database:run_cursor_command(command, {
      cursor_type = "tailable_await",
      timeout_mode = "cursor_lifetime",
    })

    assert.is_nil(cursor)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(
      "cursor_lifetime timeout mode is not supported for tailable command cursors",
      err.message
    )
    assert.are.equal(0, calls)
  end)
end)
