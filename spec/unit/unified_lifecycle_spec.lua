local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local lifecycle = require("mongodb.unified.lifecycle")

local function array(values)
  return bson.array(values)
end

local function document(entries)
  return bson.document(entries)
end

describe("unified test lifecycle", function()
  it("continues after a failed test and cleans each isolated entity map", function()
    local closed = 0
    local finalized = 0
    local asserted = 0
    local observed = 0
    local orchestrator = lifecycle.new({
      runtime = fake_runtime.new(),
      assert_events = function()
        asserted = asserted + 1
        return true
      end,
      entity_observer = function()
        observed = observed + 1
        return true
      end,
      entity_factories = {
        client = function()
          return {
            close = function()
              closed = closed + 1
              return true
            end,
          }
        end,
      },
      operations = {
        client = {
          fail = function()
            return nil, errors.new({
              category = errors.CATEGORY.INTERNAL,
              message = "expected failure",
            })
          end,
          pass = function()
            return true
          end,
        },
      },
      test_operations = {
        registerFinalizer = function(runner)
          return runner:add_finalizer(function()
            finalized = finalized + 1
            return true
          end)
        end,
      },
    })
    local report = orchestrator:run_file(document({
      { "createEntities", array({
        document({
          { "client", document({ { "id", "client0" } }) },
        }),
      }) },
      { "tests", array({
        document({
          { "description", "fails" },
          { "operations", array({
            document({ { "name", "registerFinalizer" }, { "object", "testRunner" } }),
            document({ { "name", "fail" }, { "object", "client0" } }),
          }) },
          { "expectEvents", array({}) },
        }),
        document({
          { "description", "passes" },
          { "operations", array({
            document({ { "name", "registerFinalizer" }, { "object", "testRunner" } }),
            document({ { "name", "pass" }, { "object", "client0" } }),
          }) },
          { "expectEvents", array({}) },
        }),
      }) },
    }), "fixture.json")

    assert.same({ executed = 2, failed = 1, passed = 1, selected = 2, skipped = 0 },
      report.summary)
    assert.are.equal("failed", report.tests[1].status)
    assert.are.equal("passed", report.tests[2].status)
    assert.are.equal(2, closed)
    assert.are.equal(2, finalized)
    assert.are.equal(1, asserted)
    assert.are.equal(2, observed)
  end)

  it("applies file and test requirements and skip reasons before per-test setup", function()
    local setup_count = 0
    local entity_count = 0
    local orchestrator = lifecycle.new({
      runtime = fake_runtime.new(),
      environment = { server_version = "8.0", topology = "single" },
      internal_client = {
        setup_initial_data = function()
          setup_count = setup_count + 1
          return true
        end,
      },
      entity_factories = {
        client = function()
          entity_count = entity_count + 1
          return { close = function() return true end }
        end,
      },
    })
    local tests = array({
      document({
        { "description", "explicitly skipped" },
        { "skipReason", "not on this runtime" },
        { "operations", array({}) },
      }),
      document({
        { "description", "requirements skipped" },
        { "runOnRequirements", array({
          document({ { "topologies", array({ "sharded" }) } }),
        }) },
        { "operations", array({}) },
      }),
      document({ { "description", "runs" }, { "operations", array({}) } }),
      document({ { "description", "also runs" }, { "operations", array({}) } }),
    })
    local file = document({
      { "runOnRequirements", array({
        document({ { "minServerVersion", "7.0" } }),
      }) },
      { "createEntities", array({
        document({ { "client", document({ { "id", "client0" } }) } }),
      }) },
      { "initialData", array({ document({}) }) },
      { "tests", tests },
    })
    local report = assert(orchestrator:run_file(file, "requirements.json"))

    assert.same({ executed = 2, failed = 0, passed = 2, selected = 4, skipped = 2 },
      report.summary)
    assert.are.equal("not on this runtime", report.tests[1].reason)
    assert.are.equal("test runOnRequirements not satisfied", report.tests[2].reason)
    assert.are.equal(2, setup_count)
    assert.are.equal(2, entity_count)

    local skipped = assert(orchestrator:run_file(document({
      { "runOnRequirements", array({
        document({ { "topologies", array({ "replicaset" }) } }),
      }) },
      { "initialData", array({ document({}) }) },
      { "tests", tests },
    }), "file-skipped.json"))

    assert.same({ executed = 0, failed = 0, passed = 0, selected = 4, skipped = 4 },
      skipped.summary)
    assert.are.equal(2, setup_count)
  end)

  it("orders setup, finalizers, assertions, entity access, and resource cleanup", function()
    local log = {}
    local expected_documents = array({ document({ { "_id", bson.int32(1) } }) })
    local internal_client = {
      setup_initial_data = function()
        log[#log + 1] = "initial data"
        return true
      end,
      read_outcome = function()
        log[#log + 1] = "outcome"
        return expected_documents
      end,
      close = function()
        log[#log + 1] = "internal close"
        return true
      end,
    }
    local function closing(name)
      return {
        close = function()
          log[#log + 1] = name
          return true
        end,
      }
    end
    local orchestrator = lifecycle.new({
      runtime = fake_runtime.new(),
      internal_client = internal_client,
      assert_events = function()
        log[#log + 1] = "events"
        return true
      end,
      entity_observer = function(runner)
        assert(runner:get_entity("client0", "client"))
        log[#log + 1] = "observe"
        return true
      end,
      entity_factories = {
        client = function()
          log[#log + 1] = "client created"
          return closing("client close")
        end,
        session = function()
          log[#log + 1] = "session created"
          return {
            end_session = function()
              log[#log + 1] = "session end"
              return true
            end,
          }
        end,
      },
      entity_finalizers = {
        thread = function()
          log[#log + 1] = "thread close"
          return true
        end,
      },
      operations = {
        client = {
          prepare = function(runner)
            log[#log + 1] = "operation"
            runner:add_finalizer(function()
              log[#log + 1] = "failpoint off"
              return true
            end)
            assert(runner:add_entity("find0", "findCursor", closing("find close")))
            assert(runner:add_entity("command0", "commandCursor", closing("command close")))
            assert(runner:add_entity("change0", "changeStream", closing("change close")))
            return true
          end,
        },
      },
    })
    local report = assert(orchestrator:run_file(document({
      { "createEntities", array({
        document({ { "client", document({ { "id", "client0" } }) } }),
        document({ { "session", document({ { "id", "session0" } }) } }),
        document({ { "thread", document({ { "id", "thread0" } }) } }),
      }) },
      { "initialData", array({ document({}) }) },
      { "tests", array({
        document({
          { "description", "ordered" },
          { "operations", array({
            document({ { "name", "prepare" }, { "object", "client0" } }),
          }) },
          { "expectEvents", array({}) },
          { "outcome", array({
            document({ { "documents", expected_documents } }),
          }) },
        }),
      }) },
    }), "ordered.json"))

    assert.are.equal("passed", report.tests[1].status)
    assert(orchestrator:close())
    assert.same({
      "initial data",
      "client created",
      "session created",
      "operation",
      "failpoint off",
      "events",
      "outcome",
      "observe",
      "change close",
      "command close",
      "find close",
      "thread close",
      "session end",
      "client close",
      "internal close",
    }, log)
  end)
end)
