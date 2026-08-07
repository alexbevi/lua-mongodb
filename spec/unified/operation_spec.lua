local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local unified = require("mongodb.unified.runner")

local function array(values)
  return bson.array(values)
end

local function document(entries)
  return bson.document(entries)
end

local function load_fixture(category, name)
  local path = "planning/specifications/source/unified-test-format/tests/"
    .. category .. "/" .. name .. ".json"
  local file = assert(io.open(path, "rb"))
  local contents = assert(file:read("a"))
  assert(file:close())
  return assert(bson.json.decode(contents))
end

describe("unified operation meta-fixtures", function()
  it("requires the pinned expected error response assertion", function()
    local fixture = load_fixture("valid-pass", "expectedError-errorResponse")
    local operation = fixture:get("tests"):get(1):get("operations"):get(1)
    local runner = assert(unified.new({
      runtime = fake_runtime.new(),
      operations = {
        database = {
          runCommand = function()
            return nil, errors.new({
              category = errors.CATEGORY.SERVER,
              message = "unsupported command",
            })
          end,
        },
      },
    }))
    assert(runner:add_entity("database0", "database", {}))

    local ok, err = runner:execute(operation)

    assert.is_nil(ok)
    assert.is_truthy(err.message:find("response", 1, true))
  end)

  it("executes the pinned expected error response and client-origin cases", function()
    local response_fixture = load_fixture("valid-pass", "expectedError-errorResponse")
    local runner = assert(unified.new({
      runtime = fake_runtime.new(),
      operations = {
        collection = {
          find = function()
            return nil, errors.new({
              category = errors.CATEGORY.SERVER,
              details = { response = document({ { "errmsg", "bad query" } }) },
              message = "bad query",
            })
          end,
        },
        database = {
          runCommand = function()
            return nil, errors.new({
              category = errors.CATEGORY.SERVER,
              details = { response = document({ { "errmsg", "bad command" } }) },
              message = "bad command",
            })
          end,
        },
      },
    }))
    assert(runner:add_entity("database0", "database", {}))
    assert(runner:add_entity("collection0", "collection", {}))

    for _, test in response_fixture:get("tests"):iter() do
      assert(runner:execute(test:get("operations"):get(1)), test:get("description"))
    end

    local client_fixture = load_fixture("valid-pass", "expectedError-isClientError")
    local operation = client_fixture:get("tests"):get(1):get("operations"):get(2)
    runner = assert(unified.new({
      runtime = fake_runtime.new(),
      operations = {
        database = {
          runCommand = function()
            return nil, errors.new({
              category = errors.CATEGORY.NETWORK,
              message = "connection closed",
            })
          end,
        },
      },
    }))
    assert(runner:add_entity("database0", "database", {}))
    assert(runner:execute(operation))
  end)

  it("asserts every expected error field", function()
    local response = document({
      { "code", bson.int32(42) },
      { "codeName", "BadThing" },
      { "errmsg", "Mixed CASE failure" },
    })
    local operation_error = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 42,
      code_name = "BadThing",
      details = {
        partial_result = { inserted_count = 1 },
        response = response,
        write_concern_errors = { { code = 64, message = "concern" } },
        write_errors = { { code = 42, index = 1, message = "write" } },
      },
      labels = { "RetryableWriteError" },
      message = "Mixed CASE failure",
      timeout = true,
    })
    local runner = assert(unified.new({
      runtime = fake_runtime.new(),
      operations = {
        value = {
          fail = function()
            return nil, operation_error
          end,
        },
      },
    }))
    assert(runner:add_entity("value0", "value", true))
    local expected = document({
      { "isError", true },
      { "isClientError", false },
      { "isTimeoutError", true },
      { "errorContains", "mixed case" },
      { "errorCode", bson.int32(42) },
      { "errorCodeName", "badthing" },
      { "errorLabelsContain", array({ "RetryableWriteError" }) },
      { "errorLabelsOmit", array({ "TransientTransactionError" }) },
      { "writeErrors", document({
        { "0", document({ { "code", bson.int32(42) } }) },
      }) },
      { "writeConcernErrors", array({
        document({ { "code", bson.int32(64) } }),
      }) },
      { "errorResponse", document({ { "errmsg", "Mixed CASE failure" } }) },
      { "expectResult", document({ { "insertedCount", bson.int32(1) } }) },
    })
    local function execute(expectation)
      return runner:execute(document({
        { "name", "fail" },
        { "object", "value0" },
        { "expectError", expectation },
      }))
    end

    assert(execute(expected))

    local mismatches = {
      { "isClientError", true },
      { "isTimeoutError", false },
      { "errorContains", "absent" },
      { "errorCode", bson.int32(99) },
      { "errorCodeName", "Other" },
      { "errorLabelsContain", array({ "Missing" }) },
      { "errorLabelsOmit", array({ "RetryableWriteError" }) },
      { "writeErrors", document({
        { "0", document({ { "code", bson.int32(99) } }) },
      }) },
      { "writeConcernErrors", array({
        document({ { "code", bson.int32(99) } }),
      }) },
      { "errorResponse", document({ { "missing", true } }) },
      { "expectResult", document({ { "insertedCount", bson.int32(2) } }) },
    }

    for _, mismatch in ipairs(mismatches) do
      local ok, err = execute(document({ mismatch }))
      assert.is_nil(ok, mismatch[1])
      assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION), mismatch[1])
    end
  end)

  it("executes pinned ignored, unignored, malformed, empty, and unsupported operations", function()
    local inserted = false
    local runner = assert(unified.new({
      runtime = fake_runtime.new(),
      operations = {
        collection = {
          insertOne = {
            arguments = { "document" },
            handler = function()
              if inserted then
                return nil, errors.new({
                  category = errors.CATEGORY.WRITE,
                  message = "duplicate key",
                })
              end

              inserted = true
              return document({ { "insertedId", bson.int32(1) } })
            end,
          },
        },
      },
    }))
    assert(runner:add_entity("collection0", "collection", {}))
    local pass = load_fixture("valid-pass", "ignoreResultAndError")
    assert(runner:execute_all(pass:get("tests"):get(1):get("operations")))

    inserted = false
    local fail = load_fixture("valid-fail", "ignoreResultAndError")
    local ok = runner:execute_all(fail:get("tests"):get(1):get("operations"))
    assert.is_nil(ok)

    inserted = false
    local malformed = load_fixture("valid-fail", "ignoreResultAndError-malformed")
    local _, malformed_err = runner:execute_all(
      malformed:get("tests"):get(1):get("operations")
    )
    assert.is_true(errors.is(malformed_err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("$.operations[1].arguments.foo", malformed_err.details.path)

    local empty = load_fixture("valid-pass", "operation-empty_array")
    assert(runner:execute_all(empty:get("tests"):get(1):get("operations")))

    local unsupported = load_fixture("valid-fail", "operation-unsupported")
    assert(runner:add_entity("client0", "client", {}))
    local _, unsupported_err = runner:execute_all(
      unsupported:get("tests"):get(1):get("operations")
    )
    assert.is_true(errors.is(unsupported_err, errors.CATEGORY.CONFIGURATION))
    assert.is_truthy(unsupported_err.message:find("unsupported", 1, true))
  end)

  it("executes pinned unexpected failures and missing-entity cases", function()
    local operation_error = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "server rejected operation",
    })
    local runner = assert(unified.new({
      runtime = fake_runtime.new(),
      operations = {
        collection = {
          find = function()
            return nil, operation_error
          end,
        },
        database = {
          runCommand = function()
            return nil, operation_error
          end,
        },
      },
    }))
    assert(runner:add_entity("database0", "database", {}))
    assert(runner:add_entity("collection0", "collection", {}))
    local failure = load_fixture("valid-fail", "operation-failure")

    for _, test in failure:get("tests"):iter() do
      local ok, err = runner:execute_all(test:get("operations"))
      assert.is_nil(ok, test:get("description"))
      assert.are.equal(operation_error, err)
    end

    local missing_cursor = load_fixture("valid-fail", "entity-findCursor")

    for _, test in missing_cursor:get("tests"):iter() do
      local ok, err = runner:execute_all(test:get("operations"))
      assert.is_nil(ok, test:get("description"))
      assert.is_truthy(err.message:find("unknown entity", 1, true))
    end
  end)

  it("executes pinned dynamic and invalid entity relationships", function()
    local function dependent_factory(kind, reference)
      return function(runner, specification)
        local parent, err = runner:get_entity(
          specification:get(reference),
          kind,
          "$.createEntities"
        )

        if parent == nil then
          return nil, err
        end

        return { parent = parent }
      end
    end

    local function new_runner()
      return assert(unified.new({
        runtime = fake_runtime.new(),
        entity_factories = {
          bucket = dependent_factory("database", "database"),
          client = function()
            return {}
          end,
          collection = dependent_factory("database", "database"),
          database = dependent_factory("client", "client"),
          session = dependent_factory("client", "client"),
        },
        operations = {
          collection = {
            deleteOne = {
              arguments = { "filter" },
              handler = function()
                return document({ { "deletedCount", bson.int32(0) } })
              end,
            },
          },
        },
      }))
    end

    local dynamic = load_fixture("valid-pass", "createEntities-operation")
    assert(new_runner():execute_all(dynamic:get("tests"):get(1):get("operations")))

    for _, name in ipairs({
      "entity-bucket-database-undefined",
      "entity-collection-database-undefined",
      "entity-database-client-undefined",
      "entity-session-client-undefined",
    }) do
      local fixture = load_fixture("valid-fail", name)
      local ok, err = new_runner():create_entities(fixture:get("createEntities"))
      assert.is_nil(ok, name)
      assert.is_truthy(err.message:find("unknown entity", 1, true), name)
    end
  end)

  it("resolves session arguments and preserves typed saved entities", function()
    local session = { id = "session" }
    local cursor = { id = "cursor" }
    local runner = assert(unified.new({
      runtime = fake_runtime.new(),
      operations = {
        collection = {
          createFindCursor = {
            arguments = { "filter", "session" },
            handler = function(_, _, arguments)
              assert.are.equal(session, arguments:get("session"))
              return cursor
            end,
            result_kind = "findCursor",
          },
          unsupportedResult = function()
            return {}
          end,
        },
      },
    }))
    assert(runner:add_entity("collection0", "collection", {}))
    assert(runner:add_entity("session0", "session", session))
    assert(runner:execute(document({
      { "name", "createFindCursor" },
      { "object", "collection0" },
      { "arguments", document({
        { "filter", document({}) },
        { "session", "session0" },
      }) },
      { "saveResultAsEntity", "cursor0" },
    })))
    assert.are.equal(cursor, assert(runner:get_entity("cursor0", "findCursor")))

    local ok, err = runner:execute(document({
      { "name", "unsupportedResult" },
      { "object", "collection0" },
      { "saveResultAsEntity", "bad0" },
    }))
    assert.is_nil(ok)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))

    ok, err = runner:execute(document({
      { "name", "createFindCursor" },
      { "object", "collection0" },
      { "arguments", document({
        { "filter", document({}) },
        { "session", "collection0" },
      }) },
    }))
    assert.is_nil(ok)
    assert.is_truthy(err.message:find("expected session", 1, true))
  end)
end)
