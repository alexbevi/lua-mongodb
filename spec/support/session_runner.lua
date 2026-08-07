local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local retry_executor = require("mongodb.retry_executor")
local session_module = require("mongodb.session")
local session_executor = require("mongodb.session_executor")

local M = {}

local ROOT = os.getenv("PWD") or "."

local function load_fixture(relative)
  local file = assert(io.open(
    ROOT .. "/planning/specifications/source/" .. relative,
    "rb"
  ))
  local fixture = assert(bson.json.decode(file:read("*a")))

  file:close()
  return fixture
end

local function manager()
  local next_id = 0

  return session_module.new({
    id_factory = function()
      next_id = next_id + 1
      return bson.document({
        { "id", bson.binary(
          string.rep(string.char(next_id), 16),
          bson.BINARY_SUBTYPE.UUID
        ) },
      })
    end,
    timeout_minutes = 30,
  })
end

local function encoded(value)
  return assert(bson.encode(value))
end

local function server_support(test, sessions)
  local explicit = test:get("description"):find("explicit", 1, true) ~= nil
  local first = assert(sessions:start({ causal_consistency = explicit }))
  local first_lsid = assert(first:get_lsid())

  assert(sessions:decorate(
    bson.document({ { "insert", "test" } }),
    { session = first }
  ))
  assert(first:end_session())
  local second = assert(sessions:start({ causal_consistency = false }))

  assert(sessions:decorate(
    bson.document({ { "find", "test" } }),
    { session = second }
  ))
  assert(encoded(first_lsid) == encoded(assert(second:get_lsid())))
  assert(second:end_session())
end

local function dirty_session(_, sessions)
  local explicit = assert(sessions:start())
  local dirty_lsid = encoded(assert(explicit:get_lsid()))

  assert(not explicit:is_dirty())
  assert(explicit:mark_dirty())
  assert(explicit:is_dirty())
  assert(explicit:end_session())
  local implicit = assert(sessions:start({ causal_consistency = false }))

  assert(dirty_lsid ~= encoded(assert(implicit:get_lsid())))
  assert(implicit:end_session())
end

local COMMAND_NAMES = {
  bulkWrite = "update",
  createCollection = "create",
  createIndex = "createIndexes",
  deleteMany = "delete",
  deleteOne = "delete",
  dropCollection = "drop",
  dropDatabase = "dropDatabase",
  dropIndexes = "dropIndexes",
  findOneAndDelete = "findAndModify",
  findOneAndReplace = "findAndModify",
  findOneAndUpdate = "findAndModify",
  insertMany = "insert",
  insertOne = "insert",
  replaceOne = "update",
  updateMany = "update",
  updateOne = "update",
}

local function causal_write(test, sessions)
  local session = assert(sessions:start({ causal_consistency = true }))
  local operations = test:get("operations")

  if #operations == 1 then
    local command = assert(sessions:decorate(
      bson.document({ { "insert", "test" } }),
      { session = session }
    ))

    assert(command:get("readConcern") == nil)
    assert(session:end_session())
    return
  end

  assert(session:advance_operation_time(bson.timestamp(20, 4)))
  local operation = operations:get(#operations)
  local name = assert(COMMAND_NAMES[operation:get("name")])
  local command = assert(sessions:decorate(
    bson.document({ { name, "test" } }),
    { session = session }
  ))

  assert(command:get("lsid") ~= nil)
  assert(
    command:get("readConcern"):get("afterClusterTime") == bson.timestamp(20, 4)
  )
  assert(session:end_session())
end

local function implicit_causal_retry(test, sessions, fixture)
  local read_concerns = {}

  for _, entity in fixture:get("createEntities"):iter() do
    local collection = entity:get("collection")

    if collection then
      local options = collection:get("collectionOptions")

      read_concerns[collection:get("id")] = options
        and options:get("readConcern") or nil
    end
  end

  local operation = test:get("operations"):get(2)
  local commands = {}
  local base = {}

  function base.command(_, _, command)
    commands[#commands + 1] = command

    if #commands == 1 then
      return nil, errors.new({
        category = errors.CATEGORY.SERVER,
        code = 11600,
        message = "interrupted at shutdown",
      })
    end

    return bson.document({ { "ok", 1 } })
  end

  function base.close(_)
    return true
  end

  local executor = session_executor.new(
    retry_executor.new(base),
    sessions
  )
  local read_concern = read_concerns[operation:get("object")]
  local response = assert(executor:command(
    "implicit-cc-tests",
    bson.document({ { "find", "test" } }),
    { read_concern = read_concern, retryable_read = true }
  ))

  assert(response:get("ok") == 1)
  assert(#commands == 2)
  assert(encoded(commands[1]:get("lsid")) == encoded(commands[2]:get("lsid")))

  for _, command in ipairs(commands) do
    local actual = command:get("readConcern")

    if read_concern == nil then
      assert(actual == nil)
    else
      assert(actual:get("level") == read_concern:get("level"))
      assert(actual:get("afterClusterTime") == nil)
    end
  end
end

local RUNNERS = {
  ["sessions/tests/driver-sessions-dirty-session-errors.json"] = dirty_session,
  ["sessions/tests/driver-sessions-server-support.json"] = server_support,
  ["causal-consistency/tests/causal-consistency-write-commands.json"] = causal_write,
  ["sessions/tests/implicit-sessions-default-causal-consistency.json"] =
    implicit_causal_retry,
}

function M.run(relative)
  local run = assert(RUNNERS[relative], "unsupported session fixture: " .. relative)
  local fixture = load_fixture(relative)
  local sessions = manager()
  local count = 0

  for _, test in fixture:get("tests"):iter() do
    run(test, sessions, fixture)
    count = count + 1
  end

  return count
end

return M
