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
  it("disables each failpoint on its selected server after every outcome", function()
    local active = {}
    local commands = {}
    local clients = 0
    local cleanup_clients = 0
    local cleanup_closes = 0
    local session = {}
    local function failure(message)
      return errors.new({
        category = errors.CATEGORY.SERVER,
        message = message,
      })
    end
    local failpoint_handler = failpoints.new({
      cleanup_database = function(server_address)
        if type(server_address) ~= "string" or server_address == "" then
          return nil, failure("cleanup server was not retained")
        end

        cleanup_clients = cleanup_clients + 1
        local cleanup_client = cleanup_clients
        local database = {
          run_command = function(_, command, options)
            if options.server_address ~= server_address then
              return nil, failure("cleanup did not target the retained server")
            end

            local name = command:get("configureFailPoint")

            commands[#commands + 1] = {
              cleanup_client = cleanup_client,
              command = command,
              monitor = options.monitor,
              read_preference = options.read_preference,
              server = options.server_address,
              session = options.session,
            }
            active[server_address][name] = nil
            return document({ { "ok", 1 } })
          end,
        }

        return database, function()
          cleanup_closes = cleanup_closes + 1
          return true
        end
      end,
    })
    local lifecycle = lifecycle_module.new({
      assert_events = function()
        return nil, failure("assertion failed")
      end,
      entity_factories = {
        client = function()
          clients = clients + 1
          local client_number = clients
          local server_address = "server-" .. client_number .. ":27017"
          local database = {
            run_command = function(_, command, options)
              options.on_server_selected(server_address)
              local name = command:get("configureFailPoint")

              commands[#commands + 1] = {
                client = client_number,
                command = command,
                monitor = options.monitor,
                read_preference = options.read_preference,
                server = server_address,
                session = options.session,
              }
              active[server_address] = active[server_address] or {}
              active[server_address][name] = true
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
            return nil, failure("operation failed")
          end,
          pass = function()
            return true
          end,
        },
      },
      runtime = fake_runtime.new(),
      test_operations = { failPoint = failpoint_handler },
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
    local function test(description, final_operation, assertion_failure)
      local entries = {
        { "description", description },
        { "operations", array({
          operation("failPoint", "testRunner", document({
            { "client", "client0" },
            { "failPoint", enable },
            { "session", "session0" },
          })),
          operation(final_operation, "client0"),
        }) },
      }

      if assertion_failure then
        entries[#entries + 1] = { "expectEvents", array({}) }
      end

      return document(entries)
    end
    local report = assert(lifecycle:run_file(document({
      { "createEntities", array({
        document({ { "client", document({ { "id", "client0" } }) } }),
        document({ { "session", document({ { "id", "session0" } }) } }),
      }) },
      { "tests", array({
        test("passing", "pass"),
        test("operation failure", "fail"),
        test("assertion failure", "pass", true),
      }) },
    }), "failpoints.json"))

    assert.are.equal("passed", report.tests[1].status)
    assert.are.equal("failed", report.tests[2].status)
    assert.are.equal("failed", report.tests[3].status)
    assert.are.equal(6, #commands)
    assert.are.equal(3, cleanup_closes)

    for index = 1, 6, 2 do
      assert.are.equal("failCommand", commands[index].command:get("configureFailPoint"))
      assert.is_true(bson.is_document(commands[index].command:get("mode")))
      assert.are.equal("off", commands[index + 1].command:get("mode"))
      assert.are.equal(commands[index].server, commands[index + 1].server)
      assert.is_not_nil(commands[index + 1].cleanup_client)
      assert.are.equal(session, commands[index].session)
      assert.is_nil(commands[index + 1].session)
      assert.is_false(commands[index].monitor)
      assert.is_false(commands[index + 1].monitor)
      assert.are.equal("primary", commands[index].read_preference.mode)
      assert.are.equal("primary", commands[index + 1].read_preference.mode)
    end

    for _, failpoints_by_name in pairs(active) do
      assert.is_nil(next(failpoints_by_name))
    end
  end)

  it("targets a pinned session without decorating the failpoint command", function()
    local commands = {}
    local finalizer
    local session = {
      get_pinned_server_address = function()
        return "router-a:27017"
      end,
    }
    local database = {
      run_command = function(_, command, options)
        commands[#commands + 1] = { command = command, options = options }
        options.on_server_selected = options.on_server_selected or function() end
        options.on_server_selected("router-a:27017")
        return document({ { "ok", 1 } })
      end,
    }
    local client = {
      database = function()
        return database
      end,
    }
    local runner = {
      add_finalizer = function(_, value)
        finalizer = value
      end,
      get_entity = function(_, id, kind)
        assert.are.equal("session0", id)
        assert.are.equal("session", kind)
        return session
      end,
    }
    local handler = failpoints.new({
      cleanup_database = function()
        return database
      end,
      session_client = function(value)
        assert.are.equal(session, value)
        return client
      end,
    })

    assert(handler(runner, document({
      { "failPoint", document({
        { "configureFailPoint", "failCommand" },
        { "mode", document({ { "times", 1 } }) },
      }) },
      { "session", "session0" },
    }), "$.operation"))
    assert.are.equal("router-a:27017", commands[1].options.server_address)
    assert.is_nil(commands[1].options.session)
    assert(finalizer())
    assert.are.equal("off", commands[2].command:get("mode"))
  end)
end)
