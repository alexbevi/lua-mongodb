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

describe("unified runner core", function()
  it("fails visibly for unknown entities and operations", function()
    local runner = assert(unified.new({ runtime = fake_runtime.new() }))
    local ok, err = runner:execute(document({
      { "name", "missingOperation" },
      { "object", "missingEntity" },
    }), "$.operations[1]")

    assert.is_nil(ok)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("$.operations[1].object", err.details.path)

    assert(runner:add_entity("value0", "bson", bson.int32(1)))
    ok, err = runner:execute(document({
      { "name", "missingOperation" },
      { "object", "value0" },
    }), "$.operations[2]")

    assert.is_nil(ok)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("$.operations[2].name", err.details.path)
  end)

  it("evaluates runOnRequirements as ordered alternatives", function()
    local runner = assert(unified.new({
      runtime = fake_runtime.new(),
      environment = {
        auth = true,
        server_parameters = document({ { "featureFlag", true } }),
        server_version = "8.1.2",
        serverless = false,
        topology = "replicaset",
      },
    }))
    local requirements = array({
      document({ { "minServerVersion", "9.0" } }),
      document({
        { "minServerVersion", "8.0" },
        { "maxServerVersion", "8.2" },
        { "topologies", array({ "replicaset" }) },
        { "auth", true },
        { "serverParameters", document({ { "featureFlag", true } }) },
      }),
    })

    assert.is_true(runner:should_run(requirements))
    assert.is_false(runner:should_run(array({
      document({ { "topologies", array({ "sharded" }) } }),
    })))
  end)

  it("creates fake entities, dispatches operations, saves results, and checks outcomes", function()
    local actual_outcome = array({ document({ { "_id", bson.int32(1) } }) })
    local runner = assert(unified.new({
      runtime = fake_runtime.new(),
      entity_factories = {
        counter = function()
          return { total = 0 }
        end,
      },
      operations = {
        counter = {
          increment = function(_, counter, arguments)
            counter.total = counter.total + arguments:get("amount"):to_number()
            return bson.int32(counter.total)
          end,
        },
      },
      outcome_reader = function()
        return actual_outcome
      end,
    }))

    assert(runner:create_entities(array({
      document({
        { "counter", document({ { "id", "counter0" } }) },
      }),
    })))
    assert(runner:execute(document({
      { "name", "increment" },
      { "object", "counter0" },
      { "arguments", document({ { "amount", bson.int32(2) } }) },
      { "expectResult", bson.int64(2) },
      { "saveResultAsEntity", "result0" },
    }), "$.operations[1]"))
    assert.are.equal(2, assert(runner:get_entity("result0", "bson")):to_number())
    assert(runner:verify_outcomes(array({
      document({ { "documents", actual_outcome } }),
    })))
  end)

  it("supports unified match operators and rejects unknown operators", function()
    local runner = assert(unified.new({ runtime = fake_runtime.new() }))
    assert(runner:add_entity("expected0", "bson", bson.int32(4)))
    local actual = document({
      { "count", bson.int64(4) },
      { "optional", "present" },
      { "payload", "AB" },
      { "nested", document({ { "value", bson.int32(3) } }) },
    })
    local expected = document({
      { "count", document({ { "$$matchesEntity", "expected0" } }) },
      { "optional", document({ { "$$exists", true } }) },
      { "missing", document({ { "$$exists", false } }) },
      { "payload", document({ { "$$matchesHexBytes", "4142" } }) },
      { "nested", document({
        { "value", document({ { "$$lte", bson.int32(3) } }) },
      }) },
    })

    assert(runner:match(expected, actual))
    local ok, err = runner:match(
      document({ { "value", document({ { "$$unknown", true } }) } }),
      document({ { "value", true } })
    )

    assert.is_nil(ok)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("$.value", err.details.path)
  end)

  it("runs threads and bounded loops through the deterministic runtime", function()
    local runtime = fake_runtime.new()
    local runner = assert(unified.new({
      runtime = runtime,
      entity_factories = {
        counter = function()
          return { total = 0 }
        end,
      },
      operations = {
        counter = {
          increment = function(_, counter)
            counter.total = counter.total + 1
            return bson.int32(counter.total)
          end,
        },
      },
    }))
    assert(runner:create_entities(array({
      document({ { "counter", document({ { "id", "counter0" } }) } }),
      document({ { "thread", document({ { "id", "thread0" } }) } }),
    })))
    local increment = document({
      { "name", "increment" },
      { "object", "counter0" },
    })

    assert(runner:execute(document({
      { "name", "runOnThread" },
      { "object", "testRunner" },
      { "arguments", document({
        { "thread", "thread0" },
        { "operation", increment },
      }) },
    })))
    assert(runner:execute(document({
      { "name", "waitForThread" },
      { "object", "testRunner" },
      { "arguments", document({ { "thread", "thread0" } }) },
    })))
    assert(runner:execute(document({
      { "name", "loop" },
      { "object", "testRunner" },
      { "arguments", document({
        { "operations", array({ increment }) },
        { "numIterations", bson.int32(2) },
        { "storeIterationsAsEntity", "iterations" },
        { "storeSuccessesAsEntity", "successes" },
      }) },
    })))

    assert.are.equal(2, assert(runner:get_entity("iterations", "bson")):to_number())
    assert.are.equal(2, assert(runner:get_entity("successes", "bson")):to_number())
  end)
end)
