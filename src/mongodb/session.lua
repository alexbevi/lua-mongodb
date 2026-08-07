local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local MANAGER_STATES = setmetatable({}, { __mode = "k" })
local SESSION_STATES = setmetatable({}, { __mode = "k" })
local SESSION_METHODS = {}
local SESSION_METATABLE = {
  __index = SESSION_METHODS,
  __metatable = "mongodb.client_session",
  __newindex = function()
    error("MongoDB client sessions are immutable", 2)
  end,
}

local function client_error(message)
  return nil, errors.new({
    category = errors.CATEGORY.CLIENT,
    message = message,
  })
end

local function cluster_timestamp(value)
  if not bson.is_document(value) then
    return nil
  end

  local timestamp = value:get("clusterTime")

  if bson.is_tagged(timestamp, "timestamp") then
    return timestamp
  end
end

local function later_cluster_time(left, right)
  local left_timestamp = cluster_timestamp(left)
  local right_timestamp = cluster_timestamp(right)

  if left_timestamp == nil then
    return right
  elseif right_timestamp == nil then
    return left
  end

  return left_timestamp < right_timestamp and right or left
end

local function validate_lsid(value)
  return bson.is_document(value)
    and bson.is_binary(value:get("id"))
    and value:get("id").subtype == bson.BINARY_SUBTYPE.UUID
end

local function now(state)
  return state.clock and state.clock:wall_time() or os.time()
end

local function expired(state, server_session)
  if state.timeout_minutes == nil then
    return false
  end

  return now(state) - server_session.last_used_at
    >= math.max(state.timeout_minutes - 1, 0) * 60
end

local function new_server_session(state)
  local identifier, err = state.id_factory()

  if not identifier then
    return nil, err
  end

  if not validate_lsid(identifier) then
    error("session id factory must return a UUID lsid document", 3)
  end

  return {
    dirty = false,
    id = identifier,
    last_used_at = now(state),
  }
end

local function check_session(session)
  local state = SESSION_STATES[session]

  if not state then
    return client_error("value is not a client session")
  end

  if state.ended then
    return client_error("client session has ended")
  end

  return state
end

function SESSION_METHODS:get_lsid()
  local state, err = check_session(self)

  if not state then
    return nil, err
  end

  return state.server_session.id
end

function SESSION_METHODS:advance_operation_time(value)
  local state, err = check_session(self)

  if not state then
    return nil, err
  end

  if not bson.is_tagged(value, "timestamp") then
    error("operation time must be a BSON timestamp", 2)
  end

  if state.operation_time == nil or state.operation_time < value then
    state.operation_time = value
  end

  return true
end

function SESSION_METHODS:advance_cluster_time(value)
  local state, err = check_session(self)

  if not state then
    return nil, err
  end

  if cluster_timestamp(value) == nil then
    error("cluster time must contain a BSON timestamp", 2)
  end

  state.cluster_time = later_cluster_time(state.cluster_time, value)
  return true
end

function SESSION_METHODS:mark_dirty()
  local state, err = check_session(self)

  if not state then
    return nil, err
  end

  state.server_session.dirty = true
  return true
end

function SESSION_METHODS:end_session()
  local state = SESSION_STATES[self]

  if state.ended then
    return false
  end

  state.ended = true
  local manager_state = MANAGER_STATES[state.manager]
  local server_session = state.server_session

  server_session.last_used_at = now(manager_state)
  manager_state.active[self] = nil

  if not server_session.dirty and not expired(manager_state, server_session) then
    table.insert(manager_state.pool, 1, server_session)
  end

  return true
end

function SESSION_METHODS:is_ended()
  return SESSION_STATES[self].ended
end

function SESSION_METHODS:is_dirty()
  return SESSION_STATES[self].server_session.dirty
end

function SESSION_METHODS:get_operation_time()
  return SESSION_STATES[self].operation_time
end

function SESSION_METHODS:get_cluster_time()
  return SESSION_STATES[self].cluster_time
end

local MANAGER_METHODS = {}
local MANAGER_METATABLE = {
  __index = MANAGER_METHODS,
  __metatable = "mongodb.session_manager",
  __newindex = function()
    error("MongoDB session managers are immutable", 2)
  end,
}

function MANAGER_METHODS:start(options)
  options = options or {}

  if type(options) ~= "table" then
    error("session options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "causal_consistency" then
      error("unknown session option: " .. tostring(key), 2)
    end
  end

  if options.causal_consistency ~= nil
    and type(options.causal_consistency) ~= "boolean"
  then
    error("causal_consistency must be a boolean", 2)
  end

  local manager_state = MANAGER_STATES[self]

  if manager_state.closed then
    return client_error("session manager is closed")
  end

  local server_session

  while #manager_state.pool > 0 do
    local candidate = table.remove(manager_state.pool, 1)

    if not expired(manager_state, candidate) then
      server_session = candidate
      break
    end
  end

  local err

  if server_session == nil then
    server_session, err = new_server_session(manager_state)

    if not server_session then
      return nil, err
    end
  end

  local session = {}

  SESSION_STATES[session] = {
    causal_consistency = options.causal_consistency ~= false,
    cluster_time = nil,
    ended = false,
    manager = self,
    operation_time = nil,
    server_session = server_session,
  }
  manager_state.active[session] = true
  return setmetatable(session, SESSION_METATABLE)
end

function MANAGER_METHODS:decorate(command, options)
  if not bson.is_document(command) then
    error("session command must be a BSON document", 2)
  end

  options = options or {}
  local session = options.session
  local session_state, err = check_session(session)

  if not session_state then
    return nil, err
  end

  if session_state.manager ~= self then
    return client_error("client session belongs to another client")
  end

  local manager_state = MANAGER_STATES[self]
  local entries = {}
  local add_causal_read_concern = session_state.causal_consistency
    and session_state.operation_time ~= nil

  for key, value in command:iter() do
    if key ~= "lsid" and key ~= "$clusterTime"
        and (key ~= "readConcern" or not add_causal_read_concern)
    then
      entries[#entries + 1] = { key, value }
    end
  end

  entries[#entries + 1] = { "lsid", session_state.server_session.id }
  local cluster_time = later_cluster_time(
    manager_state.cluster_time,
    session_state.cluster_time
  )

  if cluster_time then
    entries[#entries + 1] = { "$clusterTime", cluster_time }
  end

  if add_causal_read_concern then
    local read_concern = options.read_concern or command:get("readConcern")
      or bson.document({})
    local concern_entries = {}

    if not bson.is_document(read_concern) then
      error("read_concern must be a BSON document", 2)
    end

    for key, value in read_concern:iter() do
      if key ~= "afterClusterTime" then
        concern_entries[#concern_entries + 1] = { key, value }
      end
    end

    concern_entries[#concern_entries + 1] = {
      "afterClusterTime",
      session_state.operation_time,
    }
    entries[#entries + 1] = { "readConcern", bson.document(concern_entries) }
  end

  session_state.server_session.last_used_at = now(manager_state)
  return bson.document(entries)
end

function MANAGER_METHODS:advance(response, session)
  if not bson.is_document(response) then
    return true
  end

  local state = MANAGER_STATES[self]
  local cluster_time = response:get("$clusterTime")

  if cluster_timestamp(cluster_time) then
    state.cluster_time = later_cluster_time(state.cluster_time, cluster_time)

    if session then
      session:advance_cluster_time(cluster_time)
    end
  end

  local operation_time = response:get("operationTime")

  if session and bson.is_tagged(operation_time, "timestamp") then
    session:advance_operation_time(operation_time)
  end

  return true
end

function MANAGER_METHODS:close()
  local state = MANAGER_STATES[self]

  if state.closed then
    return false
  end

  local active = {}

  for session in pairs(state.active) do
    active[#active + 1] = session
  end

  for _, session in ipairs(active) do
    session:end_session()
  end

  state.closed = true
  local identifiers = {}

  for _, server_session in ipairs(state.pool) do
    identifiers[#identifiers + 1] = server_session.id
  end

  state.pool = {}
  return bson.array(identifiers)
end

function M.new(options)
  options = options or {}

  if type(options) ~= "table" then
    error("session manager options must be a table", 2)
  end

  if type(options.id_factory) ~= "function" then
    error("session manager requires an id_factory", 2)
  end

  if options.timeout_minutes ~= nil
    and (math.type(options.timeout_minutes) ~= "integer" or options.timeout_minutes < 0)
  then
    error("timeout_minutes must be a non-negative integer", 2)
  end

  local manager = {}

  MANAGER_STATES[manager] = {
    active = {},
    clock = options.clock,
    closed = false,
    cluster_time = nil,
    id_factory = options.id_factory,
    pool = {},
    timeout_minutes = options.timeout_minutes,
  }
  return setmetatable(manager, MANAGER_METATABLE)
end

return M
