local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local cursor_model = require("mongodb.cursor")
local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime")
local fake_runtime = require("mongodb.runtime.fake")

describe("find cursor lifecycle", function()
  it("pins load-balanced find and getMore until exhaustion", function()
    local pinned_connection = {}
    local release_count = 0

    function pinned_connection.release()
      release_count = release_count + 1
      return true
    end

    local executor = {
      close = function() return true end,
      command = function(_, _, command, options)
        local name = command:keys()[1]

        if name == "find" then
          assert.is_true(options.pin_connection)
          assert.is_function(options.on_connection_pinned)
          options.on_connection_pinned(pinned_connection)
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(41) },
              { "ns", "app.users" },
              { "firstBatch", bson.array({
                bson.document({ { "n", 1 } }),
              }) },
            }) },
          })
        end

        assert.are.equal("getMore", name)
        assert.are.equal(pinned_connection, options.pinned_connection)
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "app.users" },
            { "nextBatch", bson.array({
              bson.document({ { "n", 2 } }),
            }) },
          }) },
        })
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("users"):find())

    assert.are.equal(0, release_count)
    assert.are.equal(1, assert(cursor:next()):get("n"))
    assert.are.equal(0, release_count)
    assert.are.equal(2, assert(cursor:next()):get("n"))
    assert.are.equal(1, release_count)
    assert.is_true(cursor:is_closed())
    assert.is_false(cursor:close())
    assert.are.equal(1, release_count)
  end)

  it("returns an initial zero-id cursor pin immediately", function()
    local release_count = 0
    local pin = {
      release = function()
        release_count = release_count + 1
        return true
      end,
    }
    local executor = {
      close = function() return true end,
      command = function(_, _, command, options)
        assert.are.equal("find", command:keys()[1])
        options.on_connection_pinned(pin)
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "app.users" },
            { "firstBatch", bson.array({
              bson.document({ { "n", 1 } }),
            }) },
          }) },
        })
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("users"):find())

    assert.are.equal(1, release_count)
    assert.are.equal(1, assert(cursor:next()):get("n"))
    assert.is_true(cursor:is_closed())
    assert.are.equal(1, release_count)
  end)

  it("uses and returns a cursor pin when explicitly closed", function()
    local release_count = 0
    local pin = {
      release = function()
        release_count = release_count + 1
        return true
      end,
    }
    local executor = {
      close = function() return true end,
      command = function(_, _, command, options)
        local name = command:keys()[1]

        if name == "find" then
          options.on_connection_pinned(pin)
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(41) },
              { "ns", "app.users" },
              { "firstBatch", bson.array({}) },
            }) },
          })
        end

        assert.are.equal("killCursors", name)
        assert.are.equal(pin, options.pinned_connection)
        return bson.document({ { "ok", 1 } })
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("users"):find())

    assert.are.equal(0, release_count)
    assert.is_true(cursor:close())
    assert.are.equal(1, release_count)
    assert.is_false(cursor:close())
    assert.are.equal(1, release_count)
  end)

  it("releases a cursor pin when killCursors loses its connection", function()
    local commands = {}
    local release_count = 0
    local pin = {
      release = function()
        release_count = release_count + 1
        return true
      end,
    }
    local executor = {
      close = function() return true end,
      command = function(_, _, command, options)
        local name = command:keys()[1]

        commands[#commands + 1] = name

        if name == "find" then
          options.on_connection_pinned(pin)
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(41) },
              { "ns", "app.users" },
              { "firstBatch", bson.array({}) },
            }) },
          })
        end

        assert.are.equal("killCursors", name)
        assert.are.equal(pin, options.pinned_connection)
        return nil, errors.new({
          category = errors.CATEGORY.NETWORK,
          message = "killCursors connection closed",
        })
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("users"):find())

    assert.are.equal(0, release_count)
    assert.is_true(cursor:close())
    assert.same({ "find", "killCursors" }, commands)
    assert.are.equal(1, release_count)
    assert.is_false(cursor:close())
    assert.are.equal(1, release_count)
  end)

  it("releases a failed pinned getMore connection without killCursors", function()
    local commands = {}
    local release_count = 0
    local pin = {
      release = function()
        release_count = release_count + 1
        return true
      end,
    }
    local executor = {
      close = function() return true end,
      command = function(_, _, command, options)
        local name = command:keys()[1]

        commands[#commands + 1] = name

        if name == "find" then
          options.on_connection_pinned(pin)
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(41) },
              { "ns", "app.users" },
              { "firstBatch", bson.array({}) },
            }) },
          })
        end

        assert.are.equal("getMore", name)
        return nil, errors.new({
          category = errors.CATEGORY.NETWORK,
          message = "getMore connection closed",
        })
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("users"):find())
    local document, err = cursor:next()

    assert.is_nil(document)
    assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
    assert.are.equal(0, release_count)
    assert.is_true(cursor:close())
    assert.same({ "find", "getMore" }, commands)
    assert.are.equal(1, release_count)
    assert.is_false(cursor:close())
    assert.are.equal(1, release_count)
  end)

  it("retains a cursor pin after a getMore server error", function()
    local commands = {}
    local release_count = 0
    local pin = {
      release = function()
        release_count = release_count + 1
        return true
      end,
    }
    local executor = {
      close = function() return true end,
      command = function(_, _, command, options)
        local name = command:keys()[1]

        commands[#commands + 1] = name

        if name == "find" then
          options.on_connection_pinned(pin)
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(41) },
              { "ns", "app.users" },
              { "firstBatch", bson.array({}) },
            }) },
          })
        elseif name == "getMore" then
          assert.are.equal(pin, options.pinned_connection)
          return nil, errors.new({
            category = errors.CATEGORY.SERVER,
            code = 123,
            message = "getMore failed",
          })
        end

        assert.are.equal("killCursors", name)
        assert.are.equal(pin, options.pinned_connection)
        return bson.document({ { "ok", 1 } })
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("users"):find())
    local document, err = cursor:next()

    assert.is_nil(document)
    assert.is_true(errors.is(err, errors.CATEGORY.SERVER))
    assert.is_false(cursor:is_closed())
    assert.are.equal(0, release_count)
    assert.is_true(cursor:close())
    assert.same({ "find", "getMore", "killCursors" }, commands)
    assert.are.equal(1, release_count)
    assert.is_false(cursor:close())
    assert.are.equal(1, release_count)
  end)

  it("encodes and polls a non-awaitData tailable cursor", function()
    local commands = {}
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(42) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({}) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(42) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({}) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({
            bson.document({ { "_id", 1 } }),
          }) },
        }) },
      }),
    }
    local executor = {
      close = function() return true end,
      command = function(_, _, command)
        commands[#commands + 1] = command
        return table.remove(responses, 1)
      end,
    }
    local client = api.new_client(
      executor,
      assert(driver_options.normalize(nil, { timeout_ms = 50 })),
      nil,
      nil,
      nil,
      nil,
      fake_runtime.new()
    )
    local cursor = assert(client:database("app"):collection("events"):find(
      nil,
      { cursor_type = "tailable" }
    ))

    assert.is_true(commands[1]:get("tailable"))
    assert.is_nil(commands[1]:get("awaitData"))
    assert.is_nil(cursor:next())
    assert.is_false(cursor:is_closed())
    assert.are.equal(1, assert(cursor:next()):get("_id"))
    assert.is_true(cursor:is_closed())
    assert.are.same({ "find", "getMore", "getMore" }, {
      commands[1]:keys()[1],
      commands[2]:keys()[1],
      commands[3]:keys()[1],
    })
  end)

  it("encodes and polls an awaitData tailable cursor", function()
    local commands = {}
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(42) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({}) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(42) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({}) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({
            bson.document({ { "_id", 1 } }),
          }) },
        }) },
      }),
    }
    local executor = {
      close = function() return true end,
      command = function(_, _, command)
        commands[#commands + 1] = command
        return table.remove(responses, 1)
      end,
    }
    local client = api.new_client(
      executor,
      assert(driver_options.normalize(nil, { timeout_ms = 50 })),
      nil,
      nil,
      nil,
      nil,
      fake_runtime.new()
    )
    local cursor = assert(client:database("app"):collection("events"):find(
      nil,
      {
        cursor_type = "tailable_await",
        timeout_mode = "iteration",
      }
    ))

    assert.is_true(commands[1]:get("tailable"))
    assert.is_true(commands[1]:get("awaitData"))
    assert.is_nil(cursor:next())
    assert.is_false(cursor:is_closed())
    assert.are.equal(1, assert(cursor:next()):get("_id"))
    assert.is_true(cursor:is_closed())
    assert.are.same({ "find", "getMore", "getMore" }, {
      commands[1]:keys()[1],
      commands[2]:keys()[1],
      commands[3]:keys()[1],
    })
  end)

  it("rejects an awaitData wait at the client timeout", function()
    local calls = 0
    local executor = {
      close = function() return true end,
      command = function()
        calls = calls + 1
        error("command execution must not be reached")
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor, err = client:database("app"):collection("events"):find(
      nil,
      {
        cursor_type = "tailable_await",
        max_await_time_ms = 5,
        timeout_ms = 5,
      }
    )

    assert.is_nil(cursor)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal("max_await_time_ms must be less than timeout_ms", err.message)
    assert.are.equal(0, calls)
  end)

  it("applies max await time to an awaitData getMore", function()
    local commands = {}
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(42) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({}) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({}) },
        }) },
      }),
    }
    local executor = {
      close = function() return true end,
      command = function(_, _, command)
        commands[#commands + 1] = command
        return table.remove(responses, 1)
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("events"):find(
      nil,
      {
        cursor_type = "tailable_await",
        max_await_time_ms = 25,
      }
    ))

    assert.is_nil(cursor:next())
    assert.is_nil(commands[1]:get("maxTimeMS"))
    assert.are.equal(25, commands[2]:get("maxTimeMS"))
  end)

  it("keeps a cancelled awaitData cursor available for explicit close", function()
    local runtime = fake_runtime.new()
    local cancellation = runtime.cancellation:new()
    local commands = {}
    local executor = {
      close = function() return true end,
      command = function(_, _, command, options)
        local name = command:keys()[1]

        commands[#commands + 1] = name

        if name == "find" then
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(42) },
              { "ns", "app.events" },
              { "firstBatch", bson.array({}) },
            }) },
          })
        elseif name == "getMore" then
          assert.are.equal(cancellation, options.cancellation)
          cancellation:cancel("stop awaitData read")
          return runtime_contract.check(runtime, nil, options.cancellation)
        end

        return bson.document({
          { "ok", 1 },
          { "cursorsKilled", bson.array({ bson.int64(42) }) },
        })
      end,
    }
    local client = api.new_client(
      executor,
      assert(driver_options.normalize()),
      nil,
      nil,
      nil,
      nil,
      runtime
    )
    local cursor = assert(client:database("app"):collection("events"):find(
      nil,
      {
        cancellation = cancellation,
        cursor_type = "tailable_await",
      }
    ))
    local document, err = cursor:next()

    assert.is_nil(document)
    assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))
    assert.are.equal("stop awaitData read", err.message)
    assert.is_false(cursor:is_closed())
    assert.is_true(cursor:close())
    assert.is_true(cursor:is_closed())
    assert.are.same({ "find", "getMore", "killCursors" }, commands)
  end)

  it("keeps a lifetime deadline and refreshes an iteration deadline", function()
    local runtime = fake_runtime.new({ now = 2 })
    local deadlines = {}
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(1) },
          { "firstBatch", bson.array({}) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "nextBatch", bson.array({}) },
        }) },
      }),
    }
    local executor = {
      close = function() return true end,
      command = function(_, _, _, options)
        deadlines[#deadlines + 1] = options.deadline
        runtime:advance(0.010)
        return table.remove(responses, 1)
      end,
    }
    local config = assert(driver_options.normalize(nil, { timeout_ms = 50 }))
    local client = api.new_client(executor, config, nil, nil, nil, nil, runtime)
    local cursor = assert(client:database("db"):collection("items"):find(
      nil,
      { timeout_mode = "iteration" }
    ))

    assert.is_nil(cursor_model.next_until_document_or_error(cursor))
    assert.near(2.05, deadlines[1], 0.000001)
    assert.near(2.06, deadlines[2], 0.000001)
  end)

  it("keeps a timed-out cursor closable with a refreshed deadline", function()
    local runtime = fake_runtime.new({ now = 2 })
    local commands = {}
    local release_count = 0
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command, options)
        local name = command:keys()[1]

        commands[#commands + 1] = {
          deadline = options.deadline,
          name = name,
        }

        if name == "find" then
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(41) },
              { "firstBatch", bson.array({}) },
            }) },
          })
        elseif name == "getMore" then
          runtime:advance(0.250)
          return nil, errors.new({
            category = errors.CATEGORY.TIMEOUT,
            message = "getMore timed out",
          })
        end

        return bson.document({
          { "ok", 1 },
          { "cursorsKilled", bson.array({ bson.int64(41) }) },
        })
      end,
      release_session_context = function()
        release_count = release_count + 1
      end,
    }
    local config = assert(driver_options.normalize(nil, { timeout_ms = 200 }))
    local client = api.new_client(executor, config, nil, nil, nil, nil, runtime)
    local cursor = assert(client:database("db"):collection("items"):find())
    local document, err = cursor:next()

    assert.is_nil(document)
    assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))
    assert.is_false(cursor:is_closed())
    assert.are.equal(0, release_count)
    assert.is_true(cursor:close())
    assert.is_true(cursor:is_closed())
    assert.are.equal(1, release_count)
    assert.are.same({ "find", "getMore", "killCursors" }, {
      commands[1].name,
      commands[2].name,
      commands[3].name,
    })
    assert.near(2.2, commands[1].deadline, 0.000001)
    assert.near(2.2, commands[2].deadline, 0.000001)
    assert.near(2.45, commands[3].deadline, 0.000001)
  end)

  it("iterates firstBatch/getMore and kills a live cursor on close", function()
    local commands = {}
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(41) },
          { "ns", "app.users" },
          { "firstBatch", bson.array({ bson.document({ { "n", 1 } }) }) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(42) },
          { "ns", "app.users" },
          { "nextBatch", bson.array({ bson.document({ { "n", 2 } }) }) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursorsKilled", bson.array({ bson.int64(42) }) },
      }),
    }
    local executor = {
      close = function(self)
        self.closed = true
        return true
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

        return table.remove(responses, 1)
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local collection = assert(client:database("app"):collection("users"))
    local cursor = assert(collection:find(
      bson.document({ { "active", true } }),
      { batch_size = 2, limit = 5 }
    ))

    assert.are.equal(1, assert(cursor:next()):get("n"))
    assert.are.equal(2, assert(cursor:next()):get("n"))
    assert.are.equal("find", commands[1].command:keys()[1])
    assert.are.equal(2, commands[1].command:get("batchSize"))
    assert.are.equal(5, commands[1].command:get("limit"))
    assert.are.equal("getMore", commands[2].command:keys()[1])
    assert.are.equal(41, commands[2].command:get("getMore"):to_number())
    assert.are.equal(2, commands[2].command:get("batchSize"))
    assert.are.equal("router-a:27017", commands[2].options.server_address)
    assert.is_true(cursor:close())
    assert.is_false(cursor:close())
    assert.are.equal("killCursors", commands[3].command:keys()[1])
    assert.are.equal(42, commands[3].command:get("cursors"):get(1):to_number())
    assert.are.equal("router-a:27017", commands[3].options.server_address)
    assert.is_false(executor.closed == true)
  end)

  it("exhausts cleanly and applies remaining limits to getMore", function()
    local commands = {}
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(70) },
          { "ns", "app.items" },
          { "firstBatch", bson.array({ bson.document({ { "n", 1 } }) }) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(71) },
          { "ns", "app.items" },
          { "nextBatch", bson.array({ bson.document({ { "n", 2 } }) }) },
        }) },
      }),
      bson.document({ { "ok", 1 } }),
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
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("items"):find(nil, {
      batch_size = 2,
      limit = 2,
    }))

    assert.are.equal(3, commands[1]:get("batchSize"))
    assert.are.equal(1, assert(cursor:next()):get("n"))
    assert.are.equal(2, assert(cursor:next()):get("n"))
    assert.are.equal(1, commands[2]:get("batchSize"))
    assert.is_nil(cursor:next())
    assert.are.equal("killCursors", commands[3]:keys()[1])
    assert.is_true(cursor:is_closed())
    assert.are.equal(2, cursor.retrieved)
  end)

  it("kills registered cursors before client shutdown and returns getMore errors", function()
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(90) },
          { "ns", "app.logs" },
          { "firstBatch", bson.array({}) },
        }) },
      }),
    }
    local executor = {
      close = function(self)
        self.closed = true
        return true
      end,
      command = function(_, _, command)
        if command:keys()[1] == "getMore" then
          return nil, errors.new({
            category = errors.CATEGORY.NETWORK,
            message = "getMore failed",
          })
        end

        return table.remove(responses, 1)
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("logs"):find())
    local document, err = cursor:next()

    assert.is_nil(document)
    assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
    assert.is_true(cursor:is_closed())

    responses[1] = bson.document({
      { "ok", 1 },
      { "cursor", bson.document({
        { "id", bson.int64(91) },
        { "ns", "app.logs" },
        { "firstBatch", bson.array({ bson.document({ { "n", 1 } }) }) },
      }) },
    })
    responses[2] = bson.document({ { "ok", 1 } })
    cursor = assert(client:database("app"):collection("logs"):find())

    assert.is_true(client:close())
    assert.is_true(executor.closed)
    assert.is_true(cursor:is_closed())
    document, err = cursor:next()
    assert.is_nil(document)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
  end)

  it("closes locally when a zero-id nextBatch is exhausted", function()
    local command_count = 0
    local release_count = 0
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(10) },
          { "firstBatch", bson.array({ bson.document({ { "n", 1 } }) }) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "nextBatch", bson.array({ bson.document({ { "n", 2 } }) }) },
        }) },
      }),
    }
    local executor = {
      close = function()
        return true
      end,
      command = function()
        command_count = command_count + 1
        return table.remove(responses, 1)
      end,
      release_session_context = function()
        release_count = release_count + 1
      end,
    }
    local client = api.new_client(executor, assert(driver_options.normalize()))
    local cursor = assert(client:database("app"):collection("items"):find())

    assert.are.equal(1, assert(cursor:next()):get("n"))
    assert.are.equal(0, release_count)
    assert.are.equal(2, assert(cursor:next()):get("n"))
    assert.are.equal(1, release_count)
    assert.is_true(cursor:is_closed())
    assert.is_nil(cursor:next())
    assert.are.equal(2, command_count)
  end)
end)
