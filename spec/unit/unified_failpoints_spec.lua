local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local failpoints = require("mongodb.unified.failpoints")
local lifecycle_module = require("mongodb.unified.lifecycle")

local function array(values)
  return bson.array(values)
end

local function document(entries)
  return bson.document(entries)
end

describe("unified failpoints", function()
  it("disables each failpoint after passing and failing tests", function()
    local commands = {}
    local clients = 0
    local session = {}
    local lifecycle = lifecycle_module.new({
      entity_factories = {
        client = function()
          clients = clients + 1
          local client_number = clients
          local database = {
            run_command = function(_, command, options)
              commands[#commands + 1] = {
                client = client_number,
                command = command,
                monitor = options.monitor,
                read_preference = options.read_preference,
                session = options.session,
              }
              return document({ { "ok", 1 } })
            end,
          }

          return {
            close = function()
              return true
            end,
            database = function(_, name)
              assert.are.equal("admin", name)
              return database
            end,
          }
        end,
        session = function()
          return session
        end,
      },
      operations = {
        client = {
          fail = function()
            return nil, errors.new({
              category = errors.CATEGORY.SERVER,
              message = "operation failed",
            })
          end,
          pass = function()
            return true
          end,
        },
      },
      runtime = fake_runtime.new(),
      test_operations = { failPoint = failpoints.execute },
    })
    local enable = document({
      { "configureFailPoint", "failCommand" },
      { "mode", document({ { "times", 1 } }) },
    })
    local function operation(name, object, arguments)
      return document({
        { "name", name },
        { "object", object },
        { "arguments", arguments or document({}) },
      })
    end
    local function test(description, final_operation)
      return document({
        { "description", description },
        { "operations", array({
          operation("failPoint", "testRunner", document({
            { "client", "client0" },
            { "failPoint", enable },
            { "session", "session0" },
          })),
          operation(final_operation, "client0"),
        }) },
      })
    end
    local report = assert(lifecycle:run_file(document({
      { "createEntities", array({
        document({ { "client", document({ { "id", "client0" } }) } }),
        document({ { "session", document({ { "id", "session0" } }) } }),
      }) },
      { "tests", array({
        test("passing", "pass"),
        test("failing", "fail"),
      }) },
    }), "failpoints.json"))

    assert.are.equal("passed", report.tests[1].status)
    assert.are.equal("failed", report.tests[2].status)
    assert.are.equal(4, #commands)

    for index = 1, 4, 2 do
      assert.are.equal("failCommand", commands[index].command:get("configureFailPoint"))
      assert.is_true(bson.is_document(commands[index].command:get("mode")))
      assert.are.equal("off", commands[index + 1].command:get("mode"))
      assert.are.equal(commands[index].client, commands[index + 1].client)
      assert.are.equal(session, commands[index].session)
      assert.is_nil(commands[index + 1].session)
      assert.is_false(commands[index].monitor)
      assert.is_false(commands[index + 1].monitor)
      assert.are.equal("primary", commands[index].read_preference.mode)
      assert.are.equal("primary", commands[index + 1].read_preference.mode)
    end
  end)
end)
