local bson = require("mongodb.bson")
local fake_runtime = require("mongodb.runtime.fake")

local function array(values)
  return bson.array(values)
end

local function document(entries)
  return bson.document(entries)
end

local function with_fake_client(callback)
  local saved_client = package.loaded["mongodb.client"]
  local saved_driver = package.loaded["mongodb.unified.driver"]
  local connections = {}
  local client_module = {}

  function client_module.connect(_, options)
    local client = { closed = false, options = options }
    local listener = options.sdam_listeners and options.sdam_listeners[1]

    connections[#connections + 1] = client

    if listener then
      listener:TopologyOpening({})
      listener:TopologyDescriptionChanged({
        new_description = { type = "Unknown" },
        previous_description = { type = "Unknown" },
      })
      listener:TopologyDescriptionChanged({
        new_description = { type = "Single" },
        previous_description = { type = "Unknown" },
      })
    end

    function client:close()
      if self.closed then
        return false
      end

      self.closed = true

      if listener then
        listener:TopologyDescriptionChanged({
          new_description = { type = "Unknown" },
          previous_description = { type = "Single" },
        })
        listener:TopologyClosed({})
      end

      return true
    end

    function client:is_closed()
      return self.closed
    end

    return client
  end

  package.loaded["mongodb.client"] = client_module
  package.loaded["mongodb.unified.driver"] = nil
  local outcome = table.pack(pcall(function()
    callback(require("mongodb.unified.driver"), connections)
  end))

  package.loaded["mongodb.unified.driver"] = saved_driver
  package.loaded["mongodb.client"] = saved_client

  if not outcome[1] then
    error(outcome[2], 0)
  end
end

describe("unified driver lifecycle events", function()
  it("closes an observed standalone client once and matches its topology events", function()
    with_fake_client(function(driver, connections)
      local lifecycle = assert(driver.new({
        environment = { topology = "single" },
        runtime = fake_runtime.new(),
        uri = "mongodb://a:27017",
      }))
      local report = assert(lifecycle:run_file(document({
        { "tests", array({
          document({
            { "description", "Topology lifecycle" },
            { "operations", array({
              document({
                { "name", "createEntities" },
                { "object", "testRunner" },
                { "arguments", document({
                  { "entities", array({
                    document({
                      { "client", document({
                        { "id", "client" },
                        { "observeEvents", array({
                          "topologyOpeningEvent",
                          "topologyDescriptionChangedEvent",
                          "topologyClosedEvent",
                        }) },
                      }) },
                    }),
                  }) },
                }) },
              }),
              document({ { "name", "close" }, { "object", "client" } }),
            }) },
            { "expectEvents", array({
              document({
                { "client", "client" },
                { "eventType", "sdam" },
                { "events", array({
                  document({ { "topologyOpeningEvent", document({}) } }),
                  document({ { "topologyDescriptionChangedEvent", document({}) } }),
                  document({ { "topologyDescriptionChangedEvent", document({}) } }),
                  document({
                    { "topologyDescriptionChangedEvent", document({
                      { "previousDescription", document({ { "type", "Single" } }) },
                      { "newDescription", document({ { "type", "Unknown" } }) },
                    }) },
                  }),
                  document({ { "topologyClosedEvent", document({}) } }),
                }) },
              }),
            }) },
          }),
        }) },
      }), "topology-close.json"))

      assert.are.equal(1, report.summary.passed)
      assert.is_true(connections[2].closed)
      assert(lifecycle:close())
      assert.is_true(connections[1].closed)
    end)
  end)

  it("retains a topology listener for unobserved replica-set state", function()
    with_fake_client(function(driver, connections)
      local lifecycle = assert(driver.new({
        environment = { topology = "replicaset" },
        runtime = fake_runtime.new(),
        uri = "mongodb://a:27017/?replicaSet=rs",
      }))
      local report = assert(lifecycle:run_file(document({
        { "tests", array({
          document({
            { "description", "Replica-set topology state" },
            { "operations", array({
              document({
                { "name", "createEntities" },
                { "object", "testRunner" },
                { "arguments", document({
                  { "entities", array({
                    document({
                      { "client", document({ { "id", "client" } }) },
                    }),
                  }) },
                }) },
              }),
            }) },
          }),
        }) },
      }), "replicaset-state.json"))

      assert.are.equal(1, report.summary.passed)
      assert.is_not_nil(connections[2].options.sdam_listeners)
      assert.is_true(connections[2].closed)
      assert(lifecycle:close())
    end)
  end)
end)
