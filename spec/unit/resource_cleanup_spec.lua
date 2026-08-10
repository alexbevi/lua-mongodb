local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")
local pool = require("mongodb.pool")
local resource_audit = require("spec.support.resource_audit")
local fake_runtime = require("mongodb.runtime.fake")
local session_model = require("mongodb.session")
local topology = require("mongodb.topology")
local topology_executor = require("mongodb.topology_executor")
local transport = require("mongodb.network.transport")

local RESOURCE_KINDS = {
  "pool",
  "cursor",
  "session",
  "monitor",
  "connection",
  "socket",
}

local function resource_counts(value)
  local result = {}

  for _, kind in ipairs(RESOURCE_KINDS) do
    result[kind] = value
  end

  return result
end

local function server_error(message)
  return errors.new({
    category = errors.CATEGORY.SERVER,
    message = message,
  })
end

local function run_lifecycle(fail_cleanup_commands)
  local audit = resource_audit.new(RESOURCE_KINDS)
  local runtime = fake_runtime.new()
  local socket = runtime.socket:new()
  local connection_pool
  local cleanup_commands = {}
  local original_spawn = runtime.task.spawn

  runtime:queue_connect(socket)
  audit:track("socket", socket, function(value)
    return not value:is_closed()
  end)

  runtime.task.spawn = function(task_capability, callback, ...)
    local task = original_spawn(task_capability, callback, ...)

    audit:track("monitor", task, function(value)
      local status = value:status()
      return status == "pending" or status == "running"
    end)
    return task
  end

  local manager = topology.new({
    check = function()
      error("a pending monitor must not check after client closure")
    end,
    pool_factory = function(address)
      connection_pool = pool.new({
        address = address,
        connect = function()
          return transport.connect(runtime, "a", 27017)
        end,
        runtime = runtime,
      })
      audit:track("pool", connection_pool, function(value)
        return value.state ~= "closed"
      end)
      return connection_pool
    end,
    runtime = runtime,
    seeds = { "a:27017" },
    type = "Single",
  })

  assert(manager:open())
  runtime.task.spawn = original_spawn
  assert(connection_pool:ready())
  local connection = assert(connection_pool:check_out())

  audit:track("connection", connection, function(value)
    return value.state ~= "closed"
  end)
  assert(connection_pool:check_in(connection))

  local commands = topology_executor.new(manager)
  local executor = {
    capabilities = function()
      return {
        logical_session_timeout_minutes = 30,
        max_wire_version = 25,
      }
    end,
    close = function()
      return commands:close()
    end,
    command = function(_, _, command, options)
      local name = command:keys()[1]

      if name == "killCursors" or name == "endSessions" then
        cleanup_commands[name] = (cleanup_commands[name] or 0) + 1

        if fail_cleanup_commands then
          return nil, server_error(name .. " failed")
        end

        return bson.document({ { "ok", 1 } })
      end

      options.on_server_selected("a:27017")
      return bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(42) },
          { "ns", "db.items" },
          { "firstBatch", bson.array({}) },
        }) },
      })
    end,
  }
  local session_count = 0
  local sessions = session_model.new({
    clock = runtime.clock,
    id_factory = function()
      session_count = session_count + 1
      return bson.document({
        { "id", bson.binary(
          string.rep(string.char(session_count), 16),
          bson.BINARY_SUBTYPE.UUID
        ) },
      })
    end,
    runtime = runtime,
    timeout_minutes = 30,
  })
  local client = api.new_client(
    executor,
    assert(driver_options.normalize()),
    nil,
    nil,
    nil,
    sessions,
    runtime
  )
  local session = assert(client:start_session())
  local cursor = assert(client:database("db"):run_cursor_command(
    bson.document({ { "find", "items" } }),
    { session = session }
  ))

  audit:track("session", session, function(value)
    return not value:is_ended()
  end)
  audit:track("cursor", cursor, function(value)
    return not value:is_closed()
  end)
  assert.same(resource_counts(1), audit:snapshot())
  assert.is_true(client:close())
  runtime:run_all()
  assert.same({ endSessions = 1, killCursors = 1 }, cleanup_commands)
  assert.same(resource_counts(0), audit:snapshot())
end

describe("client-owned resource cleanup", function()
  it("returns every owned resource to baseline on success and failure", function()
    run_lifecycle(false)
    run_lifecycle(true)
  end)
end)
