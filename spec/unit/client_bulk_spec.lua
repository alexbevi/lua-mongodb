local api = require("mongodb.api")
local bson = require("mongodb.bson")
local client_bulk = require("mongodb.client_bulk")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local session_executor = require("mongodb.session_executor")
local session_module = require("mongodb.session")

describe("client bulk writes", function()
  it("inserts across namespaces with deduplicated namespace information", function()
    local captured
    local next_id = 0
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
          max_write_batch_size = 100000,
        }
      end,
      command = function(_, database, command, options)
        captured = {
          command = command,
          database = database,
          options = options,
        }
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "admin.$cmd.bulkWrite" },
            { "firstBatch", bson.array({}) },
          }) },
          { "nErrors", 0 },
          { "nInserted", 3 },
          { "nMatched", 0 },
          { "nModified", 0 },
          { "nUpserted", 0 },
          { "nDeleted", 0 },
        })
      end,
    }
    local object_ids = {
      new = function()
        next_id = next_id + 1
        return bson.object_id(string.format("%024x", next_id))
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config, nil, nil, object_ids)
    local first = bson.document({ { "kind", "first" } })
    local second = bson.document({ { "_id", 40 }, { "kind", "second" } })
    local third = bson.document({ { "kind", "third" } })
    local first_model = client_bulk.insert_one("app.events", first)
    local written = assert(client:bulk_write({
      first_model,
      client_bulk.insert_one("audit.events", second),
      client_bulk.insert_one("app.events", third),
    }))

    assert.is_true(written.acknowledged)
    assert.is_false(written.has_verbose_results)
    assert.is_nil(written.insert_results)
    assert.are.equal(3, written.inserted_count)
    assert.are.equal(0, written.matched_count)
    assert.are.equal(0, written.modified_count)
    assert.are.equal(0, written.upserted_count)
    assert.are.equal(0, written.deleted_count)
    assert.are.equal("admin", captured.database)
    assert.are.equal("bulkWrite", captured.command:keys()[1])
    assert.is_true(captured.command:get("errorsOnly"))
    assert.is_true(captured.command:get("ordered"))

    local ops = captured.options.sequences[1]
    local namespaces = captured.options.sequences[2]

    assert.are.equal("ops", ops.identifier)
    assert.are.equal("nsInfo", namespaces.identifier)
    assert.are.equal(3, #ops.documents)
    assert.are.equal(2, #namespaces.documents)
    assert.are.equal(0, ops.documents[1]:get("insert"):to_number())
    assert.are.equal(1, ops.documents[2]:get("insert"):to_number())
    assert.are.equal(0, ops.documents[3]:get("insert"):to_number())
    assert.are.equal("app.events", namespaces.documents[1]:get("ns"))
    assert.are.equal("audit.events", namespaces.documents[2]:get("ns"))
    assert.are.equal("_id", ops.documents[1]:get("document"):keys()[1])
    assert.are.equal("_id", ops.documents[3]:get("document"):keys()[1])
    assert.are.equal(
      bson.object_id("000000000000000000000001"),
      ops.documents[1]:get("document"):get("_id")
    )
    assert.are.equal(
      bson.object_id("000000000000000000000002"),
      ops.documents[3]:get("document"):get("_id")
    )
    assert.are.equal(40, ops.documents[2]:get("document"):get("_id"))
    assert.is_nil(first:get("_id"))
    assert.is_nil(third:get("_id"))
    assert.has_error(function()
      first_model.kind = "delete"
    end, "client bulk write models are immutable")
    assert.has_error(function()
      written.inserted_count = 4
    end, "client bulk result values are immutable")
  end)

  it("splits successful summary batches at the server count limit", function()
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
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
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "admin.$cmd.bulkWrite" },
            { "firstBatch", bson.array({}) },
          }) },
          { "nErrors", 0 },
          { "nInserted", #options.sequences[1].documents },
          { "nMatched", 0 },
          { "nModified", 0 },
          { "nUpserted", 0 },
          { "nDeleted", 0 },
        })
      end,
    }
    local client = api.new_client(
      executor,
      assert(driver_options.normalize(nil, {}))
    )
    local result = assert(client:bulk_write({
      client_bulk.insert_one(
        "app.events",
        bson.document({ { "_id", 1 } })
      ),
      client_bulk.insert_one(
        "audit.events",
        bson.document({ { "_id", 2 } })
      ),
      client_bulk.insert_one(
        "app.events",
        bson.document({ { "_id", 3 } })
      ),
    }))

    assert.are.equal(3, result.inserted_count)
    assert.are.equal(2, #commands)
    assert.are.equal("admin", commands[1].database)
    assert.are.equal("admin", commands[2].database)
    assert.are.equal(
      commands[1].options.operation_id,
      commands[2].options.operation_id
    )

    local first_ops = commands[1].options.sequences[1].documents
    local first_namespaces = commands[1].options.sequences[2].documents
    local second_ops = commands[2].options.sequences[1].documents
    local second_namespaces = commands[2].options.sequences[2].documents

    assert.are.equal(2, #first_ops)
    assert.are.equal(2, #first_namespaces)
    assert.are.equal(0, first_ops[1]:get("insert"):to_number())
    assert.are.equal(1, first_ops[2]:get("insert"):to_number())
    assert.are.equal("app.events", first_namespaces[1]:get("ns"))
    assert.are.equal("audit.events", first_namespaces[2]:get("ns"))
    assert.are.equal(1, #second_ops)
    assert.are.equal(1, #second_namespaces)
    assert.are.equal(0, second_ops[1]:get("insert"):to_number())
    assert.are.equal("app.events", second_namespaces[1]:get("ns"))
  end)

  it("sends unacknowledged batches without readable results", function()
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
          max_write_batch_size = 1,
        }
      end,
      command = function(_, database, command, options)
        commands[#commands + 1] = {
          command = command,
          database = database,
          options = options,
        }
        return bson.document({ { "ok", 1 } })
      end,
    }
    local client = api.new_client(
      executor,
      assert(driver_options.normalize(nil, {
        write_concern = { w = 0 },
      }))
    )
    local models = {
      client_bulk.insert_one(
        "app.events",
        bson.document({ { "_id", 1 } })
      ),
      client_bulk.insert_one(
        "audit.events",
        bson.document({ { "_id", 2 } })
      ),
    }
    local result = assert(client:bulk_write(models, { ordered = false }))

    assert.is_false(result.acknowledged)
    assert.is_nil(result.has_verbose_results)
    assert.is_nil(result.inserted_count)
    assert.is_nil(result.insert_results)
    assert.are.equal(2, #commands)

    for _, sent in ipairs(commands) do
      assert.are.equal("admin", sent.database)
      assert.is_true(sent.options.no_response)
      assert.are.equal(0, sent.command:get("writeConcern"):get("w"))
      assert.is_false(sent.command:get("ordered"))
    end

    assert.are.equal(
      commands[1].options.operation_id,
      commands[2].options.operation_id
    )
    assert.has_error(function()
      result.acknowledged = true
    end, "client bulk result values are immutable")

    local command_count = #commands
    local invalid, err = client:bulk_write({ models[1] }, {
      ordered = false,
      verbose_results = true,
    })

    assert.is_nil(invalid)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(
      "Cannot request unacknowledged write concern and verbose results",
      err.message
    )
    assert.are.equal(command_count, #commands)

    invalid, err = client:bulk_write({ models[1] })

    assert.is_nil(invalid)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(
      "Cannot request unacknowledged write concern and ordered writes",
      err.message
    )
    assert.are.equal(command_count, #commands)

    invalid, err = client:bulk_write({ models[1] }, {
      ordered = false,
      session = {},
    })

    assert.is_nil(invalid)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(
      "Explicit sessions are incompatible with unacknowledged write concern",
      err.message
    )
    assert.are.equal(command_count, #commands)
  end)

  it("uses one session across batches and result getMore", function()
    local next_session_id = 0
    local runtime = fake_runtime.new()
    local sessions = session_module.new({
      clock = runtime.clock,
      id_factory = function()
        next_session_id = next_session_id + 1
        return bson.document({
          { "id", bson.binary(
            string.rep(string.char(next_session_id), 16),
            bson.BINARY_SUBTYPE.UUID
          ) },
        })
      end,
      runtime = runtime,
      timeout_minutes = 30,
    })
    local operation_time = bson.timestamp(12, 4)
    local explicit = assert(sessions:start({ causal_consistency = true }))

    assert(explicit:advance_operation_time(operation_time))

    local function execute(session)
      local bulk_count = 0
      local commands = {}
      local underlying = {
        close = function()
          return true
        end,
        capabilities = function()
          return {
            max_bson_size = 16777216,
            max_message_size = 48000000,
            max_wire_version = 25,
            max_write_batch_size = 1,
          }
        end,
        command = function(_, _, command)
          commands[#commands + 1] = command

          if command:keys()[1] == "getMore" then
            return bson.document({
              { "ok", 1 },
              { "cursor", bson.document({
                { "id", bson.int64(0) },
                { "ns", "admin.$cmd.bulkWrite" },
                { "nextBatch", bson.array({}) },
              }) },
            })
          end

          bulk_count = bulk_count + 1
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(bulk_count == 2 and 42 or 0) },
              { "ns", "admin.$cmd.bulkWrite" },
              { "firstBatch", bson.array({}) },
            }) },
            { "nErrors", 0 },
            { "nInserted", 1 },
            { "nMatched", 0 },
            { "nModified", 0 },
            { "nUpserted", 0 },
            { "nDeleted", 0 },
          })
        end,
      }
      local executor = session_executor.new(underlying, sessions)
      local client = api.new_client(
        executor,
        assert(driver_options.normalize(nil, {}))
      )
      local options = session == nil and {} or { session = session }
      local result = assert(client:bulk_write({
        client_bulk.insert_one(
          "app.events",
          bson.document({ { "_id", 1 } })
        ),
        client_bulk.insert_one(
          "audit.events",
          bson.document({ { "_id", 2 } })
        ),
      }, options))

      assert.are.equal(2, result.inserted_count)
      assert.are.equal(3, #commands)
      return commands
    end

    local explicit_commands = execute(explicit)
    local explicit_id = explicit_commands[1]:get("lsid")

    assert.are.equal(explicit_id, explicit_commands[2]:get("lsid"))
    assert.are.equal(explicit_id, explicit_commands[3]:get("lsid"))
    assert.are.equal(
      operation_time,
      explicit_commands[1]:get("readConcern"):get("afterClusterTime")
    )
    assert.are.equal(
      operation_time,
      explicit_commands[2]:get("readConcern"):get("afterClusterTime")
    )

    local implicit_commands = execute()
    local implicit_id = implicit_commands[1]:get("lsid")

    assert.are.equal(implicit_id, implicit_commands[2]:get("lsid"))
    assert.are.equal(implicit_id, implicit_commands[3]:get("lsid"))
    assert.is_nil(implicit_commands[1]:get("readConcern"))
    assert.is_nil(implicit_commands[2]:get("readConcern"))
  end)

  it("rejects an operation write concern after a transaction starts", function()
    local runtime = fake_runtime.new()
    local sessions = session_module.new({
      clock = runtime.clock,
      id_factory = function()
        return bson.document({
          { "id", bson.binary(
            string.rep("t", 16),
            bson.BINARY_SUBTYPE.UUID
          ) },
        })
      end,
      runtime = runtime,
      timeout_minutes = 30,
    })
    local command_count = 0
    local underlying = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
          max_write_batch_size = 100000,
        }
      end,
      command = function()
        command_count = command_count + 1
        return bson.document({ { "ok", 1 } })
      end,
    }
    local client = api.new_client(
      session_executor.new(underlying, sessions),
      assert(driver_options.normalize(nil, {}))
    )
    local session = assert(sessions:start())

    assert(session:start_transaction())

    local result, err = client:bulk_write({
      client_bulk.insert_one(
        "app.events",
        bson.document({ { "_id", 1 } })
      ),
    }, {
      session = session,
      write_concern = { w = 1 },
    })

    assert.is_nil(result)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(
      "Cannot set write concern after starting a transaction",
      err.message
    )
    assert.are.equal(0, command_count)
  end)

  it("bounds batches by combined operation and namespace size", function()
    local first_document = bson.document({ { "_id", 1 }, { "value", "a" } })
    local second_document = bson.document({ { "_id", 2 }, { "value", "b" } })
    local first_namespace = "app.events"
    local second_namespace = "app." .. string.rep("archive", 8)
    local command = bson.document({
      { "bulkWrite", 1 },
      { "errorsOnly", true },
      { "ordered", true },
    })
    local first_operation = bson.document({
      { "insert", bson.int32(0) },
      { "document", first_document },
    })
    local second_operation = bson.document({
      { "insert", bson.int32(0) },
      { "document", second_document },
    })
    local first_ns_info = bson.document({ { "ns", first_namespace } })
    local second_ns_info = bson.document({ { "ns", second_namespace } })
    local function encoded_size(document)
      return #assert(bson.encode(document, {
        max_binary_size = 100000,
        max_document_size = 100000,
        max_string_size = 100000,
      }))
    end
    local message_size = 1000
      + encoded_size(command)
      + encoded_size(first_operation)
      + encoded_size(first_ns_info)
      + encoded_size(second_operation)

    assert.is_true(
      encoded_size(second_operation) + encoded_size(second_ns_info)
        <= message_size - 1000 - encoded_size(command)
    )

    local function run(namespace, maximum, document)
      local batches = {}
      local executor = {
        close = function()
          return true
        end,
        capabilities = function()
          return {
            max_bson_size = 16777216,
            max_message_size = maximum,
            max_wire_version = 25,
            max_write_batch_size = 100,
          }
        end,
        command = function(_, _, _, options)
          local operations = options.sequences[1].documents

          batches[#batches + 1] = options.sequences
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(0) },
              { "ns", "admin.$cmd.bulkWrite" },
              { "firstBatch", bson.array({}) },
            }) },
            { "nErrors", 0 },
            { "nInserted", #operations },
            { "nMatched", 0 },
            { "nModified", 0 },
            { "nUpserted", 0 },
            { "nDeleted", 0 },
          })
        end,
      }
      local client = api.new_client(
        executor,
        assert(driver_options.normalize(nil, {}))
      )
      local result, err = client:bulk_write({
        client_bulk.insert_one(first_namespace, first_document),
        client_bulk.insert_one(namespace, document or second_document),
      })

      return result, err, batches
    end

    local result, err, batches = run(second_namespace, message_size)

    assert.is_nil(err)
    assert.are.equal(2, result.inserted_count)
    assert.are.equal(2, #batches)
    assert.are.equal(1, #batches[1][1].documents)
    assert.are.equal(1, #batches[1][2].documents)
    assert.are.equal(first_namespace, batches[1][2].documents[1]:get("ns"))
    assert.are.equal(1, #batches[2][1].documents)
    assert.are.equal(1, #batches[2][2].documents)
    assert.are.equal(second_namespace, batches[2][2].documents[1]:get("ns"))

    result, err, batches = run(first_namespace, message_size)

    assert.is_nil(err)
    assert.are.equal(2, result.inserted_count)
    assert.are.equal(1, #batches)
    assert.are.equal(2, #batches[1][1].documents)
    assert.are.equal(1, #batches[1][2].documents)

    local one_operation_size = 1000
      + encoded_size(command)
      + encoded_size(first_operation)
      + encoded_size(first_ns_info)

    result, err, batches = run(first_namespace, one_operation_size - 1)

    assert.is_nil(result)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(0, #batches)

    result, err, batches = run(
      first_namespace,
      message_size,
      bson.document({ { "_id", 2 }, { "value", string.rep("x", message_size) } })
    )

    assert.is_nil(result)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(0, #batches)

    result, err, batches = run(
      "app." .. string.rep("namespace", message_size),
      message_size
    )

    assert.is_nil(result)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(0, #batches)
  end)

  it("merges write failures and concerns across client batches", function()
    local function success_response(inserted, concern_code)
      local entries = {
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "admin.$cmd.bulkWrite" },
          { "firstBatch", bson.array({
            bson.document({ { "ok", 1 }, { "idx", 0 }, { "n", 1 } }),
          }) },
        }) },
        { "nErrors", 0 },
        { "nInserted", inserted },
        { "nMatched", 0 },
        { "nModified", 0 },
        { "nUpserted", 0 },
        { "nDeleted", 0 },
      }

      if concern_code ~= nil then
        entries[#entries + 1] = {
          "writeConcernError",
          bson.document({
            { "code", concern_code },
            { "errmsg", "write concern " .. tostring(concern_code) },
          }),
        }
      end

      return bson.document(entries)
    end

    local function error_response(code)
      return bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "admin.$cmd.bulkWrite" },
          { "firstBatch", bson.array({
            bson.document({
              { "ok", 0 },
              { "idx", 0 },
              { "code", code },
              { "errmsg", "write error " .. tostring(code) },
            }),
          }) },
        }) },
        { "nErrors", 1 },
        { "nInserted", 0 },
        { "nMatched", 0 },
        { "nModified", 0 },
        { "nUpserted", 0 },
        { "nDeleted", 0 },
      })
    end

    local function run(ordered, responses, model_count, verbose)
      local command_count = 0
      local executor = {
        close = function()
          return true
        end,
        capabilities = function()
          return {
            max_bson_size = 16777216,
            max_message_size = 48000000,
            max_wire_version = 25,
            max_write_batch_size = 1,
          }
        end,
        command = function()
          command_count = command_count + 1
          return responses[command_count]
        end,
      }
      local client = api.new_client(
        executor,
        assert(driver_options.normalize(nil, {}))
      )
      local models = {}

      for index = 1, model_count do
        models[index] = client_bulk.insert_one(
          "app.events",
          bson.document({ { "_id", index } })
        )
      end

      local result, err = client:bulk_write(models, {
        ordered = ordered,
        verbose_results = verbose == true,
      })

      return result, err, command_count
    end

    local result, err, command_count = run(false, {
      error_response(101),
      error_response(102),
    }, 2, true)

    assert.is_nil(result)
    assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
    assert.are.equal(2, command_count)
    assert.are.equal(2, #err.details.write_errors)
    assert.are.equal(1, err.details.write_errors[1].index)
    assert.are.equal(101, err.details.write_errors[1].code)
    assert.are.equal(2, err.details.write_errors[2].index)
    assert.are.equal(102, err.details.write_errors[2].code)
    assert.is_nil(err.details.partial_result)

    result, err, command_count = run(true, {
      success_response(1),
      error_response(103),
      success_response(1),
    }, 3, true)

    assert.is_nil(result)
    assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
    assert.are.equal(2, command_count)
    assert.are.equal(1, #err.details.write_errors)
    assert.are.equal(2, err.details.write_errors[1].index)
    assert.are.equal(1, err.details.partial_result.inserted_count)
    assert.are.equal(
      1,
      err.details.partial_result.insert_results[1].inserted_id
    )
    assert.is_nil(err.details.partial_result.insert_results[2])

    result, err, command_count = run(true, {
      success_response(1, 91),
      success_response(1, 92),
    }, 2)

    assert.is_nil(result)
    assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
    assert.are.equal(2, command_count)
    assert.are.equal(0, #err.details.write_errors)
    assert.are.equal(2, #err.details.write_concern_errors)
    assert.are.equal(91, err.details.write_concern_errors[1].code)
    assert.are.equal(92, err.details.write_concern_errors[2].code)
    assert.are.equal(2, err.details.partial_result.inserted_count)
  end)

  it("translates update and replacement models without changing their values", function()
    local captured
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
          max_write_batch_size = 100000,
        }
      end,
      command = function(_, _, _, options)
        captured = options
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "admin.$cmd.bulkWrite" },
            { "firstBatch", bson.array({}) },
          }) },
          { "nErrors", 0 },
          { "nInserted", 0 },
          { "nMatched", 2 },
          { "nModified", 1 },
          { "nUpserted", 1 },
          { "nDeleted", 0 },
        })
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local filter = bson.document({ { "name", "Ada" } })
    local array_filters = bson.array({
      bson.document({ { "item.active", true } }),
    })
    local collation = bson.document({ { "locale", "en" } })
    local sort = bson.document({ { "created_at", 1 } })
    local update = bson.document({
      { "$set", bson.document({ { "active", true } }) },
      { "later_field_does_not_control_validation", true },
    })
    local pipeline = bson.array({
      bson.document({ { "$set", bson.document({ { "seen", true } }) } }),
    })
    local replacement = bson.document({
      { "name", "Ada Lovelace" },
      { "$later_field_is_allowed", true },
    })
    local written = assert(client:bulk_write({
      client_bulk.update_one("app.users", filter, update, {
        array_filters = array_filters,
        collation = collation,
        hint = "by_name",
        sort = sort,
        upsert = true,
      }),
      client_bulk.update_many("app.users", filter, pipeline, {
        hint = bson.document({ { "name", 1 } }),
      }),
      client_bulk.replace_one("audit.users", filter, replacement, {
        collation = collation,
        sort = sort,
        upsert = true,
      }),
    }))

    assert.are.equal(2, written.matched_count)
    assert.are.equal(1, written.modified_count)
    assert.are.equal(1, written.upserted_count)

    local ops = captured.sequences[1].documents

    assert.are.equal(3, #ops)
    assert.are.equal(0, ops[1]:get("update"):to_number())
    assert.are.equal(0, ops[2]:get("update"):to_number())
    assert.are.equal(1, ops[3]:get("update"):to_number())
    assert.are.equal(filter, ops[1]:get("filter"))
    assert.are.equal(update, ops[1]:get("updateMods"))
    assert.is_false(ops[1]:get("multi"))
    assert.is_true(ops[1]:get("upsert"))
    assert.are.equal(array_filters, ops[1]:get("arrayFilters"))
    assert.are.equal(collation, ops[1]:get("collation"))
    assert.are.equal("by_name", ops[1]:get("hint"))
    assert.are.equal(sort, ops[1]:get("sort"))
    assert.are.equal(pipeline, ops[2]:get("updateMods"))
    assert.is_true(ops[2]:get("multi"))
    assert.are.equal(replacement, ops[3]:get("updateMods"))
    assert.is_false(ops[3]:get("multi"))
    assert.are.same({ "locale" }, collation:keys())
    assert.are.same({ "created_at" }, sort:keys())
    assert.has_error(function()
      client_bulk.update_one("app.users", filter, replacement)
    end, "update document must begin with an atomic '$' modifier")
    assert.has_error(function()
      client_bulk.replace_one("app.users", filter, update)
    end, "replacement document must not begin with an atomic modifier")
  end)

  it("translates delete models in their mixed-operation order", function()
    local captured
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
          max_write_batch_size = 100000,
        }
      end,
      command = function(_, _, _, options)
        captured = options
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "admin.$cmd.bulkWrite" },
            { "firstBatch", bson.array({}) },
          }) },
          { "nErrors", 0 },
          { "nInserted", 1 },
          { "nMatched", 2 },
          { "nModified", 1 },
          { "nUpserted", 0 },
          { "nDeleted", 3 },
        })
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local filter = bson.document({ { "active", false } })
    local collation = bson.document({ { "locale", "en" } })
    local hint = bson.document({ { "active", 1 } })
    local written = assert(client:bulk_write({
      client_bulk.insert_one(
        "app.events",
        bson.document({ { "_id", 1 } })
      ),
      client_bulk.delete_one("app.users", filter, {
        collation = collation,
        hint = "inactive_users",
      }),
      client_bulk.update_one(
        "audit.users",
        filter,
        bson.document({ { "$set", bson.document({ { "seen", true } }) } })
      ),
      client_bulk.delete_many("app.users", filter, { hint = hint }),
      client_bulk.replace_one(
        "audit.users",
        filter,
        bson.document({ { "active", true } })
      ),
    }))

    assert.are.equal(3, written.deleted_count)

    local ops = captured.sequences[1].documents
    local namespaces = captured.sequences[2].documents

    assert.are.equal(5, #ops)
    assert.are.equal(3, #namespaces)
    assert.are.equal(0, ops[1]:get("insert"):to_number())
    assert.are.equal(1, ops[2]:get("delete"):to_number())
    assert.are.equal(2, ops[3]:get("update"):to_number())
    assert.are.equal(1, ops[4]:get("delete"):to_number())
    assert.are.equal(2, ops[5]:get("update"):to_number())
    assert.are.equal(filter, ops[2]:get("filter"))
    assert.is_false(ops[2]:get("multi"))
    assert.are.equal(collation, ops[2]:get("collation"))
    assert.are.equal("inactive_users", ops[2]:get("hint"))
    assert.are.equal(filter, ops[4]:get("filter"))
    assert.is_true(ops[4]:get("multi"))
    assert.are.equal(hint, ops[4]:get("hint"))
    assert.is_nil(ops[4]:get("collation"))
    assert.are.equal("app.events", namespaces[1]:get("ns"))
    assert.are.equal("app.users", namespaces[2]:get("ns"))
    assert.are.equal("audit.users", namespaces[3]:get("ns"))
    assert.are.same({ "locale" }, collation:keys())
    assert.are.same({ "active" }, hint:keys())
  end)

  it("exhausts the result cursor before exposing verbose results", function()
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
          max_write_batch_size = 100000,
        }
      end,
      command = function(_, database, command, options)
        commands[#commands + 1] = {
          command = command,
          database = database,
          options = options,
        }

        if command:get("bulkWrite") ~= nil then
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(91) },
              { "ns", "admin.$cmd.bulkWrite" },
              { "firstBatch", bson.array({
                bson.document({ { "ok", 1 }, { "idx", 0 }, { "n", 1 } }),
                bson.document({
                  { "ok", 1 },
                  { "idx", 1 },
                  { "n", 1 },
                  { "nModified", 1 },
                }),
              }) },
            }) },
            { "nErrors", 0 },
            { "nInserted", 1 },
            { "nMatched", 2 },
            { "nModified", 1 },
            { "nUpserted", 1 },
            { "nDeleted", 2 },
          })
        end

        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "admin.$cmd.bulkWrite" },
            { "nextBatch", bson.array({
              bson.document({
                { "ok", 1 },
                { "idx", 2 },
                { "n", 1 },
                { "nModified", 0 },
                { "upserted", bson.document({ { "_id", 4 } }) },
              }),
              bson.document({ { "ok", 1 }, { "idx", 3 }, { "n", 2 } }),
            }) },
          }) },
        })
      end,
    }
    local config = assert(driver_options.normalize(nil, {}))
    local client = api.new_client(executor, config)
    local filter = bson.document({ { "active", true } })
    local written = assert(client:bulk_write({
      client_bulk.insert_one(
        "app.users",
        bson.document({ { "_id", 8 }, { "active", true } })
      ),
      client_bulk.update_one(
        "app.users",
        filter,
        bson.document({ { "$set", bson.document({ { "seen", true } }) } })
      ),
      client_bulk.replace_one(
        "audit.users",
        filter,
        bson.document({ { "active", true } }),
        { upsert = true }
      ),
      client_bulk.delete_many("audit.users", filter),
    }, { verbose_results = true }))

    assert.is_true(written.has_verbose_results)
    assert.are.equal(1, written.inserted_count)
    assert.are.equal(2, written.matched_count)
    assert.are.equal(1, written.modified_count)
    assert.are.equal(1, written.upserted_count)
    assert.are.equal(2, written.deleted_count)
    assert.are.equal(8, written.insert_results[1].inserted_id)
    assert.are.equal(1, written.update_results[2].matched_count)
    assert.are.equal(1, written.update_results[2].modified_count)
    assert.is_nil(written.update_results[2].upserted_id)
    assert.are.equal(1, written.update_results[3].matched_count)
    assert.are.equal(0, written.update_results[3].modified_count)
    assert.are.equal(4, written.update_results[3].upserted_id)
    assert.are.equal(2, written.delete_results[4].deleted_count)
    assert.are.equal(2, #commands)
    assert.is_false(commands[1].command:get("errorsOnly"))
    assert.are.equal("admin", commands[2].database)
    assert.are.equal(91, commands[2].command:get("getMore"):to_number())
    assert.are.equal("$cmd.bulkWrite", commands[2].command:get("collection"))
    assert.has_error(function()
      written.delete_results[4].deleted_count = 3
    end, "client bulk result values are immutable")
    assert.has_error(function()
      written.delete_results[5] = written.delete_results[4]
    end, "client bulk result maps are immutable")
  end)

  it("forwards command options and overrides the inherited write concern", function()
    local captured = {}
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
          max_write_batch_size = 100000,
        }
      end,
      command = function(_, _, command, options)
        captured[#captured + 1] = { command = command, options = options }
        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "admin.$cmd.bulkWrite" },
            { "firstBatch", bson.array({}) },
          }) },
          { "nErrors", 0 },
          { "nInserted", 1 },
          { "nMatched", 0 },
          { "nModified", 0 },
          { "nUpserted", 0 },
          { "nDeleted", 0 },
        })
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      write_concern = { w = 2 },
    }))
    local client = api.new_client(executor, config)
    local comment = bson.document({ { "bulk", "write" } })
    local variables = bson.document({ { "tenant", 14 } })
    local model = client_bulk.insert_one(
      "app.users",
      bson.document({ { "_id", 1 } })
    )

    assert(client:bulk_write({ model }, {
      bypass_document_validation = false,
      comment = comment,
      let = variables,
      ordered = false,
      verbose_results = false,
      write_concern = { journal = true, w = "majority", w_timeout_ms = 250 },
    }))
    assert(client:bulk_write({ model }))

    local explicit = captured[1].command
    local inherited = captured[2].command

    assert.is_true(explicit:get("errorsOnly"))
    assert.is_false(explicit:get("ordered"))
    assert.is_false(explicit:get("bypassDocumentValidation"))
    assert.are.equal(comment, explicit:get("comment"))
    assert.are.equal(variables, explicit:get("let"))
    assert.is_true(explicit:get("writeConcern"):get("j"))
    assert.are.equal("majority", explicit:get("writeConcern"):get("w"))
    assert.are.equal(250, explicit:get("writeConcern"):get("wtimeout"))
    assert.are.equal(2, inherited:get("writeConcern"):get("w"))
    assert.are.same({ "bulk" }, comment:keys())
    assert.are.same({ "tenant" }, variables:keys())
  end)

  it("sends raw data only at the MongoDB 8.2 wire version", function()
    local function executor_for(max_wire_version)
      local captured
      local executor = {
        close = function()
          return true
        end,
        capabilities = function()
          return {
            max_bson_size = 16777216,
            max_message_size = 48000000,
            max_wire_version = max_wire_version,
            max_write_batch_size = 100000,
          }
        end,
        command = function(_, _, command)
          captured = command
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(0) },
              { "ns", "admin.$cmd.bulkWrite" },
              { "firstBatch", bson.array({}) },
            }) },
            { "nErrors", 0 },
            { "nInserted", 1 },
            { "nMatched", 2 },
            { "nModified", 1 },
            { "nUpserted", 0 },
            { "nDeleted", 1 },
          })
        end,
      }

      return executor, function()
        return captured
      end
    end

    local config = assert(driver_options.normalize(nil, {}))
    local filter = bson.document({ { "_id", 1 } })
    local models = {
      client_bulk.insert_one(
        "app.users",
        bson.document({ { "_id", 1 } })
      ),
      client_bulk.update_one(
        "app.users",
        filter,
        bson.document({ { "$set", bson.document({ { "seen", true } }) } })
      ),
      client_bulk.replace_one(
        "audit.users",
        filter,
        bson.document({ { "seen", true } })
      ),
      client_bulk.delete_one("audit.users", filter),
    }
    local modern_executor, modern_command = executor_for(27)
    local older_executor, older_command = executor_for(25)
    local modern = api.new_client(modern_executor, config)
    local older = api.new_client(older_executor, config)

    assert(modern:bulk_write(models, { raw_data = true }))
    assert(older:bulk_write(models, { raw_data = true }))
    assert.is_true(modern_command():get("rawData"))
    assert.is_nil(older_command():get("rawData"))
  end)

  it("reports ordered and unordered individual errors at original indexes", function()
    local error_info = bson.document({ { "expression", "$$missing" } })
    local function run(ordered, result_documents)
      local executor = {
        close = function()
          return true
        end,
        capabilities = function()
          return {
            max_bson_size = 16777216,
            max_message_size = 48000000,
            max_wire_version = 25,
            max_write_batch_size = 100000,
          }
        end,
        command = function()
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(0) },
              { "ns", "admin.$cmd.bulkWrite" },
              { "firstBatch", bson.array(result_documents) },
            }) },
            { "nErrors", #result_documents },
            { "nInserted", 0 },
            { "nMatched", 0 },
            { "nModified", 0 },
            { "nUpserted", 0 },
            { "nDeleted", 0 },
          })
        end,
      }
      local client = api.new_client(
        executor,
        assert(driver_options.normalize(nil, {}))
      )
      local filter = bson.document({ { "active", true } })
      local result, err = client:bulk_write({
        client_bulk.delete_one("app.users", filter),
        client_bulk.update_one(
          "app.users",
          filter,
          bson.document({ { "$set", bson.document({ { "seen", true } }) } })
        ),
        client_bulk.delete_many("audit.users", filter),
      }, { ordered = ordered })

      assert.is_nil(result)
      assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
      return err
    end
    local function write_error(index, code, message)
      return bson.document({
        { "ok", 0 },
        { "idx", bson.int32(index) },
        { "code", bson.int32(code) },
        { "errmsg", message },
        { "errInfo", error_info },
      })
    end
    local ordered = run(true, {
      write_error(1, 17276, "undefined variable"),
    })
    local unordered = run(false, {
      write_error(0, 11000, "duplicate key"),
      write_error(2, 2, "bad value"),
    })

    assert.are.equal(17276, ordered.code)
    assert.are.equal("undefined variable", ordered.message)
    assert.are.equal(1, #ordered.details.write_errors)
    assert.are.equal(2, ordered.details.write_errors[1].index)
    assert.are.equal(error_info, ordered.details.write_errors[1].details)
    assert.are.equal(
      "update",
      ordered.details.write_errors[1].operation:keys()[1]
    )
    assert.are.equal(2, #unordered.details.write_errors)
    assert.are.equal(1, unordered.details.write_errors[1].index)
    assert.are.equal(11000, unordered.details.write_errors[1].code)
    assert.are.equal(3, unordered.details.write_errors[2].index)
    assert.are.equal(2, unordered.details.write_errors[2].code)
  end)

  it("returns partial results only after a confirmed successful model", function()
    local function write_error(index)
      return bson.document({
        { "ok", 0 },
        { "idx", bson.int32(index) },
        { "code", bson.int32(11000) },
        { "errmsg", "duplicate key" },
      })
    end
    local function success(index)
      return bson.document({
        { "ok", 1 },
        { "idx", bson.int32(index) },
        { "n", bson.int32(1) },
      })
    end
    local function run(ordered, verbose, result_documents, n_errors, inserted)
      local executor = {
        close = function()
          return true
        end,
        capabilities = function()
          return {
            max_bson_size = 16777216,
            max_message_size = 48000000,
            max_wire_version = 25,
            max_write_batch_size = 100000,
          }
        end,
        command = function()
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(0) },
              { "ns", "admin.$cmd.bulkWrite" },
              { "firstBatch", bson.array(result_documents) },
            }) },
            { "nErrors", n_errors },
            { "nInserted", inserted },
            { "nMatched", 0 },
            { "nModified", 0 },
            { "nUpserted", 0 },
            { "nDeleted", 0 },
          })
        end,
      }
      local client = api.new_client(
        executor,
        assert(driver_options.normalize(nil, {}))
      )
      local result, err = client:bulk_write({
        client_bulk.insert_one(
          "app.users",
          bson.document({ { "_id", 1 } })
        ),
        client_bulk.insert_one(
          "app.users",
          bson.document({ { "_id", 2 } })
        ),
      }, {
        ordered = ordered,
        verbose_results = verbose,
      })

      assert.is_nil(result)
      assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
      return err.details.partial_result
    end

    assert.is_nil(run(true, true, { write_error(0) }, 1, 0))

    local ordered_verbose = assert(run(
      true,
      true,
      { success(0), write_error(1) },
      1,
      1
    ))
    local ordered_summary = assert(run(
      true,
      false,
      { write_error(1) },
      1,
      1
    ))

    assert.are.equal(1, ordered_verbose.inserted_count)
    assert.is_true(ordered_verbose.has_verbose_results)
    assert.are.equal(1, ordered_verbose.insert_results[1].inserted_id)
    assert.has_error(function()
      ordered_verbose.inserted_count = 2
    end, "client bulk result values are immutable")
    assert.are.equal(1, ordered_summary.inserted_count)
    assert.is_false(ordered_summary.has_verbose_results)
    assert.is_nil(ordered_summary.insert_results)
    assert.is_nil(run(
      false,
      false,
      { write_error(0), write_error(1) },
      2,
      0
    ))

    local unordered_verbose = assert(run(
      false,
      true,
      { write_error(0), success(1) },
      1,
      1
    ))

    assert.are.equal(1, unordered_verbose.inserted_count)
    assert.are.equal(2, unordered_verbose.insert_results[2].inserted_id)
    assert.is_nil(unordered_verbose.insert_results[1])
  end)

  it("reports a write concern error after exhausting successful results", function()
    local commands = {}
    local error_info = bson.document({
      { "writeConcern", bson.document({ { "w", "majority" } }) },
    })
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
          max_write_batch_size = 100000,
        }
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command

        if #commands == 1 then
          return bson.document({
            { "ok", 1 },
            { "cursor", bson.document({
              { "id", bson.int64(44) },
              { "ns", "admin.$cmd.bulkWrite" },
              { "firstBatch", bson.array({
                bson.document({
                  { "ok", 1 },
                  { "idx", bson.int32(0) },
                  { "n", bson.int32(1) },
                }),
              }) },
            }) },
            { "nErrors", 0 },
            { "nInserted", 1 },
            { "nMatched", 0 },
            { "nModified", 0 },
            { "nUpserted", 0 },
            { "nDeleted", 0 },
            { "writeConcernError", bson.document({
              { "code", bson.int32(91) },
              { "codeName", "ShutdownInProgress" },
              { "errmsg", "replication is shutting down" },
              { "errInfo", error_info },
            }) },
            { "errorLabels", bson.array({ "RetryableWriteError" }) },
          })
        end

        return bson.document({
          { "ok", 1 },
          { "cursor", bson.document({
            { "id", bson.int64(0) },
            { "ns", "admin.$cmd.bulkWrite" },
            { "nextBatch", bson.array({}) },
          }) },
        })
      end,
    }
    local client = api.new_client(
      executor,
      assert(driver_options.normalize(nil, {}))
    )
    local result, err = client:bulk_write({
      client_bulk.insert_one(
        "app.users",
        bson.document({ { "_id", 1 } })
      ),
    }, { verbose_results = true })

    assert.is_nil(result)
    assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
    assert.are.equal(91, err.code)
    assert.are.equal("ShutdownInProgress", err.code_name)
    assert.are.equal("replication is shutting down", err.message)
    assert.is_true(err:has_label("RetryableWriteError"))
    assert.are.equal(2, #commands)
    assert.are.equal(44, commands[2]:get("getMore"):to_number())
    assert.are.equal(0, #err.details.write_errors)
    assert.are.equal(1, #err.details.write_concern_errors)
    assert.are.equal(91, err.details.write_concern_errors[1].code)
    assert.are.equal(error_info, err.details.write_concern_errors[1].details)
    assert.are.equal(1, err.details.partial_result.inserted_count)
    assert.are.equal(
      1,
      err.details.partial_result.insert_results[1].inserted_id
    )
  end)

  it("preserves a top-level command failure without cursor work", function()
    local response = bson.document({
      { "ok", 0 },
      { "code", bson.int32(8) },
      { "codeName", "UnknownError" },
      { "errmsg", "failpoint command error" },
      { "errorLabels", bson.array({ "RetryableWriteError" }) },
    })
    local command_error = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 8,
      code_name = "UnknownError",
      details = { response = response },
      labels = { "RetryableWriteError" },
      message = "failpoint command error",
    })
    local commands = 0
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return {
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
          max_write_batch_size = 100000,
        }
      end,
      command = function()
        commands = commands + 1
        return nil, command_error
      end,
    }
    local client = api.new_client(
      executor,
      assert(driver_options.normalize(nil, {}))
    )
    local result, err = client:bulk_write({
      client_bulk.insert_one(
        "app.users",
        bson.document({ { "_id", 1 } })
      ),
    }, { verbose_results = true })

    assert.is_nil(result)
    assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
    assert.is_true(errors.is(err.cause, errors.CATEGORY.SERVER))
    assert.are.equal(command_error, err.cause)
    assert.are.equal(8, err.code)
    assert.are.equal("UnknownError", err.code_name)
    assert.are.equal("failpoint command error", err.message)
    assert.is_true(err:has_label("RetryableWriteError"))
    assert.are.equal(response, err.details.response)
    assert.is_nil(err.details.partial_result)
    assert.are.equal(0, #err.details.write_errors)
    assert.are.equal(0, #err.details.write_concern_errors)
    assert.are.equal(1, commands)
  end)

  it("closes a failed result cursor with checked cleanup", function()
    local response = bson.document({
      { "ok", 0 },
      { "code", bson.int32(8) },
      { "codeName", "UnknownError" },
      { "errmsg", "failpoint getMore error" },
      { "errorLabels", bson.array({ "RetryableWriteError" }) },
    })
    local get_more_error = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 8,
      code_name = "UnknownError",
      details = { response = response },
      labels = { "RetryableWriteError" },
      message = "failpoint getMore error",
    })

    local function run(cleanup_error)
      local commands = {}
      local executor = {
        close = function()
          return true
        end,
        capabilities = function()
          return {
            max_bson_size = 16777216,
            max_message_size = 48000000,
            max_wire_version = 25,
            max_write_batch_size = 100000,
          }
        end,
        command = function(_, _, command)
          commands[#commands + 1] = command

          if #commands == 1 then
            return bson.document({
              { "ok", 1 },
              { "cursor", bson.document({
                { "id", bson.int64(44) },
                { "ns", "admin.$cmd.bulkWrite" },
                { "firstBatch", bson.array({
                  bson.document({
                    { "ok", 1 },
                    { "idx", bson.int32(0) },
                    { "n", bson.int32(1) },
                  }),
                }) },
              }) },
              { "nErrors", 0 },
              { "nInserted", 2 },
              { "nMatched", 0 },
              { "nModified", 0 },
              { "nUpserted", 0 },
              { "nDeleted", 0 },
            })
          end

          if #commands == 2 then
            return nil, get_more_error
          end

          if cleanup_error ~= nil then
            return nil, cleanup_error
          end

          return bson.document({
            { "ok", 1 },
            { "cursorsKilled", bson.array({ bson.int64(44) }) },
          })
        end,
      }
      local client = api.new_client(
        executor,
        assert(driver_options.normalize(nil, {}))
      )
      local result, err = client:bulk_write({
        client_bulk.insert_one(
          "app.users",
          bson.document({ { "_id", 1 } })
        ),
        client_bulk.insert_one(
          "app.users",
          bson.document({ { "_id", 2 } })
        ),
      }, { verbose_results = true })

      assert.is_nil(result)
      assert.is_true(errors.is(err, errors.CATEGORY.WRITE))
      assert.are.equal(get_more_error, err.cause)
      assert.are.equal(8, err.code)
      assert.are.equal("UnknownError", err.code_name)
      assert.are.equal("failpoint getMore error", err.message)
      assert.is_true(err:has_label("RetryableWriteError"))
      assert.are.equal(response, err.details.response)
      assert.are.equal(cleanup_error, err.details.cleanup_error)
      assert.are.equal(2, err.details.partial_result.inserted_count)
      assert.are.equal(
        1,
        err.details.partial_result.insert_results[1].inserted_id
      )
      assert.is_nil(err.details.partial_result.insert_results[2])
      assert.are.equal(0, #err.details.write_errors)
      assert.are.equal(0, #err.details.write_concern_errors)
      assert.are.equal(3, #commands)
      assert.are.equal("getMore", commands[2]:keys()[1])
      assert.are.equal(44, commands[2]:get("getMore"):to_number())
      assert.are.equal("killCursors", commands[3]:keys()[1])
      assert.are.equal("$cmd.bulkWrite", commands[3]:get("killCursors"))
      assert.are.equal(
        44,
        commands[3]:get("cursors"):get(1):to_number()
      )
    end

    run()
    run(errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "killCursors failed",
    }))
  end)
end)
