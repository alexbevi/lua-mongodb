local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")

describe("collection change streams", function()
  it("opens, yields from, and closes a collection stream", function()
    local commands = {}
    local event = bson.document({
      { "_id", bson.document({ { "token", 1 } }) },
      { "operationType", "insert" },
    })
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(42) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({ event }) },
        }) },
      }),
      bson.document({ { "ok", 1 } }),
    }
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
        return table.remove(responses, 1)
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local collection = assert(client:database("app"):collection("events"))
    local match = bson.document({
      { "$match", bson.document({ { "operationType", "insert" } }) },
    })
    local stream = assert(collection:watch(bson.array({ match })))

    assert.are.equal("mongodb.change_stream", getmetatable(stream))
    assert.is_nil(stream.cursor)
    assert.are.equal(event, assert(stream:next()))
    assert.is_true(stream:close())
    assert.is_true(stream:is_closed())

    local aggregate = commands[1]
    local pipeline = aggregate.command:get("pipeline")

    assert.are.equal("app", aggregate.database)
    assert.are.equal("aggregate", aggregate.command:keys()[1])
    assert.are.equal("events", aggregate.command:get("aggregate"))
    assert.are.equal(2, #pipeline)
    assert.are.equal("$changeStream", pipeline:get(1):keys()[1])
    assert.are.equal(0, #pipeline:get(1):get("$changeStream"))
    assert.are.equal(match, pipeline:get(2))
    assert.is_true(aggregate.options.retryable_read)

    local kill = commands[2]

    assert.are.equal("killCursors", kill.command:keys()[1])
    assert.are.equal("events", kill.command:get("killCursors"))
    assert.are.equal(42, kill.command:get("cursors"):get(1):to_number())
  end)

  it("forwards stage options without validating server-owned values", function()
    local command
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, sent)
        command = sent
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "app.events" },
            { "firstBatch", bson.array({}) },
          }) },
        })
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local collection = assert(client:database("app"):collection("events"))

    local cases = {
      { "full_document", "fullDocument", "futureServerMode" },
      {
        "full_document_before_change",
        "fullDocumentBeforeChange",
        "futureBeforeMode",
      },
      { "resume_after", "resumeAfter", bson.document({ { "token", 1 } }) },
      { "start_after", "startAfter", bson.document({ { "token", 2 } }) },
      {
        "start_at_operation_time",
        "startAtOperationTime",
        bson.timestamp(9, 3),
      },
      { "show_expanded_events", "showExpandedEvents", false },
    }

    for _, case in ipairs(cases) do
      local options = { [case[1]] = case[3] }

      assert(collection:watch(nil, options))

      local stage = command:get("pipeline"):get(1):get("$changeStream")

      assert.are.equal(1, #stage)
      assert.are.equal(case[3], stage:get(case[2]))
      assert.are.equal(case[3], options[case[1]])
    end

    assert.has_error(function()
      collection:watch(nil, { show_expanded_events = "yes" })
    end, "show_expanded_events must be a boolean")
  end)

  it("places aggregate and getMore options on their commands", function()
    local commands = {}
    local change = bson.document({
      { "_id", bson.document({ { "token", 3 } }) },
      { "operationType", "insert" },
    })
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(43) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({}) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({ change }) },
        }) },
      }),
    }
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
        return table.remove(responses, 1)
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      read_concern = { level = "majority" },
      read_preference = { mode = "secondary" },
    }))
    local client = api.new_client(executor, config)
    local collection = assert(client:database("app"):collection("events"))
    local collation = bson.document({ { "locale", "en" } })
    local comment = bson.document({ { "trace", 1 } })
    local session = {}
    local options = {
      batch_size = 3,
      collation = collation,
      comment = comment,
      max_await_time_ms = 250,
      session = session,
    }
    local stream = assert(collection:watch(nil, options))

    assert.are.equal(change, assert(stream:next()))

    local aggregate = commands[1]
    local cursor_options = aggregate.command:get("cursor")

    assert.are.equal(3, cursor_options:get("batchSize"))
    assert.are.equal(collation, aggregate.command:get("collation"))
    assert.are.equal(comment, aggregate.command:get("comment"))
    assert.are.equal("majority", aggregate.command:get("readConcern"):get("level"))
    assert.is_nil(aggregate.command:get("maxAwaitTimeMS"))
    assert.are.equal(session, aggregate.options.session)
    assert.are.equal("secondary", aggregate.options.read_preference.mode)

    local get_more = commands[2]

    assert.are.equal("getMore", get_more.command:keys()[1])
    assert.are.equal(3, get_more.command:get("batchSize"))
    assert.are.equal(comment, get_more.command:get("comment"))
    assert.are.equal(250, get_more.command:get("maxTimeMS"))
    assert.is_nil(get_more.command:get("collation"))
    assert.are.equal(session, get_more.options.session)
    assert.are.equal(collation, options.collation)
    assert.are.equal(comment, options.comment)
  end)

  it("returns cooperatively after one empty live batch", function()
    local commands = {}
    local change = bson.document({
      { "_id", bson.document({ { "token", 4 } }) },
      { "operationType", "insert" },
    })
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(44) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({}) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(44) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({}) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(44) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({}) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({ change }) },
        }) },
      }),
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
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local collection = assert(client:database("app"):collection("events"))
    local stream = assert(collection:watch())

    assert.is_nil(stream:try_next())
    assert.are.equal(2, #commands)
    assert.are.equal("getMore", commands[2]:keys()[1])
    assert.is_false(stream:is_closed())

    assert.are.equal(change, assert(stream:next()))
    assert.are.equal(4, #commands)
    assert.is_true(stream:is_closed())
  end)

  it("starts with the configured resume token", function()
    local initial = bson.document({ { "token", "initial" } })
    local post_batch = bson.document({ { "token", "post-batch" } })
    local response
    local executor = {
      close = function()
        return true
      end,
      command = function()
        return response
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local collection = assert(client:database("app"):collection("events"))

    for _, option in ipairs({ "start_after", "resume_after" }) do
      response = bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({}) },
        }) },
      })
      local stream = assert(collection:watch(nil, { [option] = initial }))

      assert.are.equal(initial, stream:resume_token())
    end

    response = bson.document({
      { "ok", 1 },
      { "cursor", bson.document({
        { "id", bson.int64(0) },
        { "ns", "app.events" },
        { "firstBatch", bson.array({}) },
        { "postBatchResumeToken", post_batch },
      }) },
    })

    local stream = assert(collection:watch(nil, { start_after = initial }))

    assert.are.equal(post_batch, stream:resume_token())
  end)

  it("uses document tokens until the last document in a batch", function()
    local first_token = bson.document({ { "token", 1 } })
    local second_token = bson.document({ { "token", 2 } })
    local post_batch = bson.document({ { "token", 3 } })
    local first = bson.document({
      { "_id", first_token },
      { "operationType", "insert" },
    })
    local second = bson.document({
      { "_id", second_token },
      { "operationType", "update" },
    })
    local executor = {
      close = function()
        return true
      end,
      command = function()
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "app.events" },
            { "firstBatch", bson.array({ first, second }) },
            { "postBatchResumeToken", post_batch },
          }) },
        })
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local stream = assert(client:database("app"):collection("events"):watch())

    assert.is_nil(stream:resume_token())
    assert.are.equal(first, assert(stream:next()))
    assert.are.equal(first_token, stream:resume_token())
    assert.are.equal(second, assert(stream:next()))
    assert.are.equal(post_batch, stream:resume_token())
  end)

  it("uses the post-batch token from an empty live batch", function()
    local post_batch = bson.document({ { "token", 4 } })
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(46) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({}) },
        }) },
      }),
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(46) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({}) },
          { "postBatchResumeToken", post_batch },
        }) },
      }),
      bson.document({ { "ok", 1 } }),
    }
    local executor = {
      close = function()
        return true
      end,
      command = function()
        return table.remove(responses, 1)
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local stream = assert(client:database("app"):collection("events"):watch())

    assert.is_nil(stream:try_next())
    assert.are.equal(post_batch, stream:resume_token())
    assert.is_false(stream:is_closed())
    assert.is_true(stream:close())
  end)

  it("closes when a returned change has no resume token", function()
    local commands = {}
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(47) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({
            bson.document({ { "operationType", "insert" } }),
          }) },
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
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local stream = assert(client:database("app"):collection("events"):watch())
    local change, err = stream:next()

    assert.is_nil(change)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.matches("Cannot provide resume functionality", err.message, 1, true)
    assert.is_true(stream:is_closed())
    assert.are.equal("killCursors", commands[2]:keys()[1])
  end)

  it("recreates once after a modern resumable error label", function()
    local commands = {}
    local sent_options = {}
    local session = {}
    local resume_token = bson.document({ { "token", "resume" } })
    local change = bson.document({
      { "_id", bson.document({ { "token", 5 } }) },
      { "operationType", "insert" },
    })
    local responses = {
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(48) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({}) },
          { "postBatchResumeToken", resume_token },
        }) },
      }),
      false,
      bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({ change }) },
        }) },
      }),
    }
    local executor = {
      capabilities = function()
        return { max_wire_version = 25 }
      end,
      close = function()
        return true
      end,
      command = function(_, _, command, options)
        commands[#commands + 1] = command
        sent_options[#sent_options + 1] = options
        local response = table.remove(responses, 1)

        if response == false then
          return nil, errors.new({
            category = errors.CATEGORY.SERVER,
            code = 50,
            labels = { "ResumableChangeStreamError" },
            message = "temporary getMore failure",
          })
        end

        return response
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      read_preference = { mode = "secondary" },
    }))
    local client = api.new_client(executor, config)
    local stream = assert(client:database("app"):collection("events"):watch(
      nil,
      { session = session }
    ))

    assert.are.equal(change, assert(stream:next()))
    assert.are.same({ "aggregate", "getMore", "aggregate" }, {
      commands[1]:keys()[1],
      commands[2]:keys()[1],
      commands[3]:keys()[1],
    })
    assert.are.equal(
      resume_token,
      commands[3]:get("pipeline"):get(1):get("$changeStream"):get("resumeAfter")
    )
    assert.are.equal(session, sent_options[3].session)
    assert.are.equal("secondary", sent_options[3].read_preference.mode)
  end)

  it("classifies network, cursor, legacy, and modern server errors", function()
    local resumable_codes = {
      6, 7, 43, 63, 89, 91, 133, 150, 189, 234, 262, 9001,
      10107, 11600, 11602, 13388, 13435, 13436,
    }

    local function run_case(max_wire_version, first_error, should_resume)
      local commands = {}
      local change = bson.document({
        { "_id", bson.document({ { "token", 6 } }) },
        { "operationType", "insert" },
      })
      local executor = {
        capabilities = function()
          return { max_wire_version = max_wire_version }
        end,
        close = function()
          return true
        end,
        command = function(_, _, command)
          commands[#commands + 1] = command

          if #commands == 1 then
            return bson.document({
              { "ok", 1 },
              { "cursor", bson.document({
                { "id", bson.int64(49) },
                { "ns", "app.events" },
                { "firstBatch", bson.array({}) },
              }) },
            })
          elseif #commands == 2 then
            return nil, first_error
          end

          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(0) },
              { "ns", "app.events" },
              { "firstBatch", bson.array({ change }) },
            }) },
          })
        end,
      }
      local config = assert(driver_options.normalize(nil, {}))
      local client = api.new_client(executor, config)
      local stream = assert(client:database("app"):collection("events"):watch())
      local document, err = stream:next()

      if should_resume then
        assert.are.equal(change, document)
        assert.is_nil(err)
        assert.are.equal(3, #commands)
      else
        assert.is_nil(document)
        assert.are.equal(first_error, err)
        assert.are.equal(2, #commands)
      end
    end

    for _, code in ipairs(resumable_codes) do
      run_case(8, errors.new({
        category = errors.CATEGORY.SERVER,
        code = code,
        message = "legacy resumable failure",
      }), true)
    end

    run_case(8, errors.new({
      category = errors.CATEGORY.SERVER,
      code = 42,
      message = "legacy terminal failure",
    }), false)
    run_case(25, errors.new({
      category = errors.CATEGORY.SERVER,
      code = 6,
      message = "modern unlabeled failure",
    }), false)
    run_case(25, errors.new({
      category = errors.CATEGORY.SERVER,
      code = 43,
      message = "cursor not found",
    }), true)
    run_case(25, errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "network interrupted",
    }), true)
  end)

  it("does not resume again after recreating the cursor", function()
    local first_error = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 50,
      labels = { "ResumableChangeStreamError" },
      message = "first interruption",
    })
    local second_error = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 50,
      labels = { "ResumableChangeStreamError" },
      message = "second interruption",
    })

    local function run_case(resume_aggregate_fails)
      local commands = {}
      local executor = {
        capabilities = function()
          return { max_wire_version = 25 }
        end,
        close = function()
          return true
        end,
        command = function(_, _, command)
          commands[#commands + 1] = command

          if #commands == 1 then
            return bson.document({
              { "ok", 1 },
              { "cursor", bson.document({
                { "id", bson.int64(50) },
                { "ns", "app.events" },
                { "firstBatch", bson.array({}) },
              }) },
            })
          elseif #commands == 2 then
            return nil, first_error
          elseif #commands == 3 and resume_aggregate_fails then
            return nil, second_error
          elseif #commands == 3 then
            return bson.document({
              { "ok", 1 },
              { "cursor", bson.document({
                { "id", bson.int64(51) },
                { "ns", "app.events" },
                { "firstBatch", bson.array({}) },
              }) },
            })
          end

          return nil, second_error
        end,
      }
      local config = assert(driver_options.normalize(nil, {}))
      local client = api.new_client(executor, config)
      local stream = assert(client:database("app"):collection("events"):watch())
      local document, err = stream:next()

      assert.is_nil(document)
      assert.are.equal(second_error, err)
      assert.are.equal(resume_aggregate_fails and 3 or 4, #commands)
    end

    run_case(true)
    run_case(false)
  end)

  it("suppresses cleanup errors while recreating", function()
    local commands = {}
    local resume_token = bson.document({ { "token", "cleanup" } })
    local change = bson.document({
      { "_id", bson.document({ { "token", 7 } }) },
      { "operationType", "insert" },
    })
    local network_error = errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "connection interrupted",
    })
    local timeout_error = errors.new({
      category = errors.CATEGORY.TIMEOUT,
      cause = network_error,
      message = "getMore timed out",
    })
    local executor = {
      capabilities = function()
        return { max_wire_version = 25 }
      end,
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command

        if #commands == 1 then
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(52) },
              { "ns", "app.events" },
              { "firstBatch", bson.array({}) },
              { "postBatchResumeToken", resume_token },
            }) },
          })
        elseif #commands == 2 then
          return nil, timeout_error
        elseif #commands == 3 then
          return nil, network_error
        end

        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "app.events" },
            { "firstBatch", bson.array({ change }) },
          }) },
        })
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local stream = assert(client:database("app"):collection("events"):watch())

    assert.are.equal(change, assert(stream:next()))
    assert.are.same({ "aggregate", "getMore", "killCursors", "aggregate" }, {
      commands[1]:keys()[1],
      commands[2]:keys()[1],
      commands[3]:keys()[1],
      commands[4]:keys()[1],
    })
  end)
end)
