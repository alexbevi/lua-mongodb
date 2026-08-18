local bson = require("mongodb.bson")
local errors = require("mongodb.error")
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
  local cluster_time = document({
    { "clusterTime", bson.timestamp(9, 4) },
    { "signature", document({}) },
  })

  function client_module.connect(uri, options)
    local client = {
      closed = false,
      created_collections = {},
      modified_collections = {},
      options = options,
      sessions = {},
      uri = uri,
    }
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

    function client:start_session(session_options)
      local session = {
        ended = false,
        options = session_options,
        snapshot_time = session_options.snapshot
          and (session_options.snapshot_time or bson.timestamp(7, 3)) or nil,
      }

      function session.end_session()
        session.ended = true
        return true
      end

      function session.get_snapshot_time()
        return session.snapshot_time
      end

      function session.get_pinned_server_address()
        return "b:27017"
      end

      function session.advance_cluster_time(_, value)
        session.cluster_time = value
        return true
      end

      self.sessions[#self.sessions + 1] = session
      return session
    end

    function client.database(_, name)
      local database = {}

      function database.drop_collection()
        return true
      end

      function database.create_collection(_, collection_name, collection_options)
        client.created_collections[#client.created_collections + 1] = {
          name = collection_name,
          options = collection_options,
        }
        return true
      end

      function database.modify_collection(_, collection_name, collection_options)
        client.modified_collections[#client.modified_collections + 1] = {
          name = collection_name,
          options = collection_options,
        }
        return true
      end

      function database.collection()
        local collection = {}

        function collection.insert_many()
          return true
        end

        function collection.watch()
          local stream = {}

          function stream.next()
            client.change_stream_next_calls =
              (client.change_stream_next_calls or 0) + 1
            return document({ { "operationType", "update" } })
          end

          function stream.close()
            return true
          end

          return stream
        end

        return collection
      end

      function database.run_command(_, command, command_options)
        assert.are.equal("admin", name)

        if command:get("configureFailPoint") ~= nil then
          if command_options.on_server_selected then
            command_options.on_server_selected(
              command_options.server_address or "b:27017"
            )
          end

          return document({ { "ok", 1 } })
        end

        assert.are.equal(1, command:get("ping"))
        return document({
          { "ok", 1 },
          { "$clusterTime", cluster_time },
        })
      end

      return database
    end

    return client
  end

  package.loaded["mongodb.client"] = client_module
  package.loaded["mongodb.unified.driver"] = nil
  local outcome = table.pack(pcall(function()
    callback(require("mongodb.unified.driver"), connections, cluster_time)
  end))

  package.loaded["mongodb.unified.driver"] = saved_driver
  package.loaded["mongodb.client"] = saved_client

  if not outcome[1] then
    error(outcome[2], 0)
  end
end

describe("unified driver collection management", function()
  it("forwards change stream images when creating a collection", function()
    with_fake_client(function(driver, connections)
      local lifecycle = assert(driver.new({
        environment = { topology = "replicaset" },
        runtime = fake_runtime.new(),
        uri = "mongodb://a:27017/?replicaSet=rs",
      }))
      local images = document({ { "enabled", true } })
      local report = assert(lifecycle:run_file(document({
        { "createEntities", array({
          document({
            { "client", document({ { "id", "client0" } }) },
          }),
          document({
            { "database", document({
              { "id", "database0" },
              { "client", "client0" },
              { "databaseName", "app" },
            }) },
          }),
        }) },
        { "tests", array({
          document({
            { "description", "Create collection with change stream images" },
            { "operations", array({
              document({
                { "name", "createCollection" },
                { "object", "database0" },
                { "arguments", document({
                  { "collection", "events" },
                  { "changeStreamPreAndPostImages", images },
                }) },
              }),
            }) },
          }),
        }) },
      }), "create-collection-images.json"))

      assert.are.equal(1, report.summary.passed)
      assert.are.equal("events", connections[2].created_collections[1].name)
      assert.are.equal(
        images,
        connections[2].created_collections[1].options
          .change_stream_pre_and_post_images
      )
      assert(lifecycle:close())
    end)
  end)

  it("forwards change stream images when modifying a collection", function()
    with_fake_client(function(driver, connections)
      local lifecycle = assert(driver.new({
        environment = { topology = "replicaset" },
        runtime = fake_runtime.new(),
        uri = "mongodb://a:27017/?replicaSet=rs",
      }))
      local images = document({ { "enabled", true } })
      local report = assert(lifecycle:run_file(document({
        { "createEntities", array({
          document({
            { "client", document({ { "id", "client0" } }) },
          }),
          document({
            { "database", document({
              { "id", "database0" },
              { "client", "client0" },
              { "databaseName", "app" },
            }) },
          }),
        }) },
        { "tests", array({
          document({
            { "description", "Modify collection change stream images" },
            { "operations", array({
              document({
                { "name", "modifyCollection" },
                { "object", "database0" },
                { "arguments", document({
                  { "collection", "events" },
                  { "changeStreamPreAndPostImages", images },
                }) },
              }),
            }) },
          }),
        }) },
      }), "modify-collection-images.json"))

      assert.are.equal(1, report.summary.passed)
      assert.are.equal("events", connections[2].modified_collections[1].name)
      assert.are.equal(
        images,
        connections[2].modified_collections[1].options
          .change_stream_pre_and_post_images
      )
      assert(lifecycle:close())
    end)
  end)
end)

describe("unified driver change streams", function()
  it("uses blocking stream iteration until a document or error", function()
    with_fake_client(function(driver, connections)
      local lifecycle = assert(driver.new({
        environment = { topology = "replicaset" },
        runtime = fake_runtime.new(),
        uri = "mongodb://a:27017/?replicaSet=rs",
      }))
      local report = assert(lifecycle:run_file(document({
        { "createEntities", array({
          document({
            { "client", document({ { "id", "client0" } }) },
          }),
          document({
            { "database", document({
              { "id", "database0" },
              { "client", "client0" },
              { "databaseName", "app" },
            }) },
          }),
          document({
            { "collection", document({
              { "id", "collection0" },
              { "database", "database0" },
              { "collectionName", "events" },
            }) },
          }),
        }) },
        { "tests", array({
          document({
            { "description", "Block until a change document" },
            { "operations", array({
              document({
                { "name", "createChangeStream" },
                { "object", "collection0" },
                { "arguments", document({}) },
                { "saveResultAsEntity", "changeStream0" },
              }),
              document({
                { "name", "iterateUntilDocumentOrError" },
                { "object", "changeStream0" },
                { "arguments", document({}) },
                { "expectResult", document({
                  { "operationType", "update" },
                }) },
              }),
            }) },
          }),
        }) },
      }), "change-stream-blocking-iteration.json"))

      assert.are.equal(1, report.summary.passed)
      assert.are.equal(1, connections[2].change_stream_next_calls)
      assert(lifecycle:close())
    end)
  end)
end)

describe("unified driver lifecycle events", function()
  it("cleans targeted failpoints through the multiple-mongos URI", function()
    with_fake_client(function(driver, connections)
      local multiple_mongos_uri = "mongodb://a:27017,b:27017"
      local lifecycle = assert(driver.new({
        environment = { topology = "sharded" },
        multiple_mongos_uri = multiple_mongos_uri,
        runtime = fake_runtime.new(),
        uri = "mongodb://a:27017",
      }))
      local report = assert(lifecycle:run_file(document({
        { "createEntities", array({
          document({
            { "client", document({
              { "id", "client0" },
              { "useMultipleMongoses", true },
            }) },
          }),
          document({
            { "session", document({
              { "id", "session0" },
              { "client", "client0" },
            }) },
          }),
        }) },
        { "tests", array({
          document({
            { "description", "Targeted cleanup" },
            { "operations", array({
              document({
                { "name", "targetedFailPoint" },
                { "object", "testRunner" },
                { "arguments", document({
                  { "session", "session0" },
                  { "failPoint", document({
                    { "configureFailPoint", "failCommand" },
                    { "mode", document({ { "times", 1 } }) },
                  }) },
                }) },
              }),
            }) },
          }),
        }) },
      }), "targeted-cleanup.json"))

      assert.are.equal(1, report.summary.passed)
      assert.are.equal(multiple_mongos_uri, connections[3].uri)
      assert(lifecycle:close())
    end)
  end)

  it("advances sessions to the sharded initial-data cluster time", function()
    with_fake_client(function(driver, connections, cluster_time)
      local lifecycle = assert(driver.new({
        environment = { topology = "sharded" },
        multiple_mongos_uri = "mongodb://a:27017,b:27017",
        runtime = fake_runtime.new(),
        uri = "mongodb://a:27017",
      }))
      local report = assert(lifecycle:run_file(document({
        { "initialData", array({
          document({
            { "collectionName", "test" },
            { "databaseName", "transaction-tests" },
            { "documents", array({}) },
          }),
        }) },
        { "createEntities", array({
          document({
            { "client", document({
              { "id", "client0" },
              { "useMultipleMongoses", true },
            }) },
          }),
          document({
            { "session", document({
              { "id", "session0" },
              { "client", "client0" },
            }) },
          }),
        }) },
        { "tests", array({
          document({
            { "description", "Sharded transaction setup" },
            { "operations", array({}) },
          }),
        }) },
      }), "sharded-transaction.json"))

      assert.are.equal(1, report.summary.passed)
      assert.are.equal(cluster_time, connections[2].sessions[1].cluster_time)
      assert(lifecycle:close())
    end)
  end)

  it("forwards monitor timing URI options", function()
    with_fake_client(function(driver, connections)
      local lifecycle = assert(driver.new({
        environment = { topology = "sharded" },
        runtime = fake_runtime.new(),
        uri = "mongodb://a:27017",
      }))
      local report = assert(lifecycle:run_file(document({
        { "tests", array({
          document({
            { "description", "Monitor timing options" },
            { "operations", array({
              document({
                { "name", "createEntities" },
                { "object", "testRunner" },
                { "arguments", document({
                  { "entities", array({
                    document({
                      { "client", document({
                        { "id", "client" },
                        { "uriOptions", document({
                          { "connectTimeoutMS", 250 },
                          { "heartbeatFrequencyMS", 500 },
                        }) },
                      }) },
                    }),
                  }) },
                }) },
              }),
            }) },
          }),
        }) },
      }), "monitor-options.json"))

      assert.are.equal(1, report.summary.passed)
      assert.are.equal(250, connections[2].options.connect_timeout_ms)
      assert.are.equal(500, connections[2].options.heartbeat_frequency_ms)
      assert(lifecycle:close())
    end)
  end)

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

  it("round-trips snapshot time entities and rejects unknown arguments", function()
    with_fake_client(function(driver, connections)
      local lifecycle = assert(driver.new({
        environment = { topology = "replicaset" },
        runtime = fake_runtime.new(),
        uri = "mongodb://a:27017/?replicaSet=rs",
      }))
      local report = assert(lifecycle:run_file(document({
        { "createEntities", array({
          document({
            { "client", document({ { "id", "client0" } }) },
          }),
          document({
            { "session", document({
              { "id", "session0" },
              { "client", "client0" },
              { "sessionOptions", document({ { "snapshot", true } }) },
            }) },
          }),
        }) },
        { "tests", array({
          document({
            { "description", "Snapshot time entity round trip" },
            { "operations", array({
              document({
                { "name", "getSnapshotTime" },
                { "object", "session0" },
                { "saveResultAsEntity", "savedSnapshotTime" },
              }),
              document({
                { "name", "createEntities" },
                { "object", "testRunner" },
                { "arguments", document({
                  { "entities", array({
                    document({
                      { "session", document({
                        { "id", "session2" },
                        { "client", "client0" },
                        { "sessionOptions", document({
                          { "snapshot", true },
                          { "snapshotTime", "savedSnapshotTime" },
                        }) },
                      }) },
                    }),
                  }) },
                }) },
              }),
            }) },
          }),
          document({
            { "description", "Unknown snapshot time argument" },
            { "operations", array({
              document({
                { "name", "getSnapshotTime" },
                { "object", "session0" },
                { "arguments", document({ { "unknown", true } }) },
              }),
            }) },
          }),
        }) },
      }), "snapshot-time.json"))

      assert.are.same({
        executed = 2,
        failed = 1,
        passed = 1,
        selected = 2,
        skipped = 0,
      }, report.summary)
      assert.are.equal(
        bson.timestamp(7, 3),
        connections[2].sessions[2].options.snapshot_time
      )
      assert.is_true(errors.is(
        report.tests[2].error,
        errors.CATEGORY.CONFIGURATION
      ))
      assert.are.equal(
        "$.tests[2].operations[1].arguments.unknown",
        report.tests[2].error.details.path
      )
      assert(lifecycle:close())
    end)
  end)
end)
