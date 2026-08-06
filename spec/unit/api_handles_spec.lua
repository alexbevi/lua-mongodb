local api = require("mongodb.api")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local driver_options = require("mongodb.config.options")

describe("core MongoDB handles", function()
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
end)
