local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local operation_timeout = require("mongodb.operation_timeout")

local M = {}

local MANAGER_STATES = setmetatable({}, { __mode = "k" })
local SESSION_STATES = setmetatable({}, { __mode = "k" })
local SESSION_METHODS = {}
local WITH_TRANSACTION_TIMEOUT_SECONDS = 120
local TRANSACTION_BACKOFF_INITIAL_SECONDS = 0.005
local TRANSACTION_BACKOFF_MAX_SECONDS = 0.500
local READ_COMMANDS = {
  aggregate = true,
  count = true,
  distinct = true,
  find = true,
  getMore = true,
  listCollections = true,
  listDatabases = true,
  listIndexes = true,
}
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
  return state.clock:now()
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
    transaction_number = 0,
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
  return SESSION_STATES[self].server_session.id
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
    return true
  end

  if state.transaction.state == "starting"
      or state.transaction.state == "in_progress"
  then
    self:abort_transaction()
  end

  self:unpin_server()
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

function SESSION_METHODS:get_snapshot_time()
  return SESSION_STATES[self].snapshot_time
end

function SESSION_METHODS:get_timeout_context()
  local state = SESSION_STATES[self]
  local manager = MANAGER_STATES[state.manager]

  return manager.runtime, state.timeout_ms
end

local function transaction_active(transaction)
  return transaction.state == "starting" or transaction.state == "in_progress"
end

local function retryable_transaction_command(name, err)
  return errors.is(err, errors.CATEGORY.NETWORK)
    or errors.is(err, errors.CATEGORY.TIMEOUT)
    or err:has_label("RetryableWriteError")
    or (name == "commitTransaction" or name == "abortTransaction")
      and errors.is(err, errors.CATEGORY.AUTHENTICATION)
      and err:is_retryable()
end

local function read_preference_mode(value)
  if bson.is_document(value) then
    return value:get("mode")
  elseif type(value) == "table" then
    return value.mode
  end
end

function SESSION_METHODS:is_in_transaction()
  return transaction_active(SESSION_STATES[self].transaction)
end

function SESSION_METHODS:get_transaction_state()
  return SESSION_STATES[self].transaction.state
end

function SESSION_METHODS:get_pinned_server_address()
  return SESSION_STATES[self].transaction.pinned_server_address
end

function SESSION_METHODS:get_pinned_connection()
  return SESSION_STATES[self].transaction.pinned_connection
end

function SESSION_METHODS:is_pinned()
  return self:get_pinned_server_address() ~= nil
    or self:get_pinned_connection() ~= nil
end

function SESSION_METHODS:uses_connection_pinning()
  local state = SESSION_STATES[self]

  return MANAGER_STATES[state.manager].load_balanced
end

function SESSION_METHODS:unpin_server()
  local state, err = check_session(self)

  if not state then
    return nil, err
  end

  local pinned = state.transaction.pinned_server_address ~= nil

  state.transaction.pinned_server_address = nil
  return pinned
end

function SESSION_METHODS:pin_server(address, server_type)
  local state, err = check_session(self)

  if not state then
    return nil, err
  end

  if type(address) ~= "string" or address == "" then
    error("pinned server address must be a non-empty string", 2)
  end

  if server_type ~= "Mongos" or not transaction_active(state.transaction) then
    return false
  end

  local pinned = state.transaction.pinned_server_address

  if pinned ~= nil and pinned ~= address then
    error("transaction selected a different mongos than its pin", 2)
  end

  state.transaction.pinned_server_address = address
  return true
end

function SESSION_METHODS:pin_connection(pin)
  local state, err = check_session(self)

  if not state then
    return nil, err
  end

  if type(pin) ~= "table" or type(pin.release) ~= "function" then
    error("pinned connection must expose release", 2)
  end

  if not self:uses_connection_pinning()
      or not transaction_active(state.transaction)
  then
    return false
  end

  local pinned = state.transaction.pinned_connection

  if pinned ~= nil and pinned ~= pin then
    error("transaction selected a different connection than its pin", 2)
  end

  state.transaction.pinned_connection = pin
  return true
end

function SESSION_METHODS:unpin_connection()
  local state, err = check_session(self)

  if not state then
    return nil, err
  end

  local pin = state.transaction.pinned_connection

  if pin == nil then
    return false
  end

  state.transaction.pinned_connection = nil
  pin:release()
  return true
end

function SESSION_METHODS:start_transaction(options)
  local state, err = check_session(self)

  if not state then
    return nil, err
  end

  if state.snapshot then
    return client_error("Transactions are not supported in snapshot sessions")
  end

  if transaction_active(state.transaction) then
    return client_error("transaction already in progress")
  end

  options = options or {}

  if type(options) ~= "table" then
    error("transaction options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "max_commit_time_ms" and key ~= "read_concern"
        and key ~= "read_preference" and key ~= "write_concern"
    then
      error("unknown transaction option: " .. tostring(key), 2)
    end
  end

  if options.read_concern ~= nil and not bson.is_document(options.read_concern) then
    error("transaction read_concern must be a BSON document", 2)
  end

  if options.write_concern ~= nil and not bson.is_document(options.write_concern) then
    error("transaction write_concern must be a BSON document", 2)
  end

  if options.read_preference ~= nil
      and not bson.is_document(options.read_preference)
      and type(options.read_preference) ~= "table"
  then
    error("transaction read_preference must be a table or BSON document", 2)
  end

  local transaction_options = {}

  for key, value in pairs(state.default_transaction_options) do
    transaction_options[key] = value
  end

  for key, value in pairs(options) do
    transaction_options[key] = value
  end

  local write_concern = transaction_options.write_concern
  local w = write_concern and write_concern:get("w")

  if bson.is_exact(w) then
    w = w:to_number()
  end

  if w == 0 then
    return client_error("transactions do not support unacknowledged write concern")
  end

  state.server_session.transaction_number =
    state.server_session.transaction_number + 1
  self:unpin_server()
  state.transaction = { options = transaction_options, state = "starting" }
  return true
end

local function finish_transaction(session, name, options)
  local state, err = check_session(session)

  if not state then
    return nil, err
  end

  options = options or {}

  if type(options) ~= "table" then
    error("transaction command options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "timeout_ms" then
      error("unknown transaction command option: " .. tostring(key), 2)
    end
  end

  local transaction = state.transaction

  if operation_timeout.current() == nil
      and (state.timeout_ms ~= nil or options.timeout_ms ~= nil)
  then
    local manager = MANAGER_STATES[state.manager]

    return operation_timeout.run(manager.runtime, state.timeout_ms, options, function()
      return finish_transaction(session, name, {})
    end)
  end

  if transaction.state == "none" then
    return client_error("no transaction started")
  elseif name == "commitTransaction" and transaction.state == "aborted" then
    return client_error(
      "Cannot call commitTransaction after calling abortTransaction"
    )
  elseif name == "abortTransaction" and transaction.state == "aborted" then
    return client_error("cannot call abortTransaction twice")
  elseif name == "abortTransaction"
      and (transaction.state == "committed"
        or transaction.state == "committed_empty")
  then
    return client_error(
      "Cannot call abortTransaction after calling commitTransaction"
    )
  end

  if transaction.state == "starting" then
    transaction.state = name == "commitTransaction"
      and "committed_empty" or "aborted"
    return true
  end

  if name == "commitTransaction" and transaction.state == "committed_empty" then
    return true
  end

  local retrying_commit = false
  if name == "commitTransaction" and transaction.state == "committed" then
    transaction.state = "in_progress"
    retrying_commit = true
  end

  local manager = MANAGER_STATES[state.manager]

  if type(manager.transaction_command) ~= "function" then
    return client_error("session manager cannot execute transaction commands")
  end

  local response
  response, err = manager.transaction_command(
    session,
    name,
    transaction.options,
    retrying_commit
  )

  if err and retryable_transaction_command(name, err) then
    session:unpin_server()
    response, err = manager.transaction_command(
      session,
      name,
      transaction.options,
      name == "commitTransaction"
    )
  end

  if err and name == "commitTransaction" then
    if errors.is(err, errors.CATEGORY.NETWORK)
        or errors.is(err, errors.CATEGORY.TIMEOUT)
    then
      err = errors.with_label(err, "RetryableWriteError")
    end

    if errors.is(err, errors.CATEGORY.NETWORK)
        or errors.is(err, errors.CATEGORY.TIMEOUT)
        or errors.is(err, errors.CATEGORY.WRITE)
          and err.code ~= 79 and err.code ~= 100
        or err.code == 50
        or err:has_label("RetryableWriteError")
    then
      err = errors.with_label(err, "UnknownTransactionCommitResult")
    end
  end
  transaction.state = name == "commitTransaction" and "committed" or "aborted"

  if name == "abortTransaction" then
    return true, nil, err
  end

  return response, err
end

function SESSION_METHODS:commit_transaction(options)
  local response, err = finish_transaction(self, "commitTransaction", options)

  if err and (err:has_label("TransientTransactionError")
      or err:has_label("UnknownTransactionCommitResult"))
  then
    self:unpin_server()
  end

  return response, err
end

function SESSION_METHODS:abort_transaction(options)
  local response, err, command_err = finish_transaction(
    self,
    "abortTransaction",
    options
  )

  if SESSION_STATES[self].transaction.state == "aborted" then
    self:unpin_server()

    if command_err
        and not command_err:has_label("TransientTransactionError")
        and not retryable_transaction_command("abortTransaction", command_err)
    then
      self:unpin_connection()
    end
  end

  return response, err
end

local function abort_with_refreshed_timeout(session)
  local context = operation_timeout.current()

  if context == nil then
    return session:abort_transaction()
  end

  return operation_timeout.resume(context, true, function()
    return session:abort_transaction()
  end)
end

local function retry_timeout(err)
  if err:is_timeout() then
    return err
  end

  local labels = {}

  for index, label in ipairs(err.labels) do
    labels[index] = label
  end

  return errors.new({
    category = errors.CATEGORY.TIMEOUT,
    cause = err,
    labels = labels,
    message = "with_transaction retry time limit exceeded: " .. err.message,
  })
end

local function within_retry_time(manager, started_at, delay)
  local context = operation_timeout.current()

  if context and context.deadline then
    return manager.clock:now() + (delay or 0) < context.deadline
  elseif context then
    return true
  end

  return manager.clock:now() + (delay or 0) - started_at
    < manager.transaction_retry_timeout_seconds
end

local function sleep_before_transaction_retry(manager, started_at, attempt, err)
  if operation_timeout.current() then
    return true
  end

  local jitter, jitter_err = manager.transaction_jitter()

  if jitter == nil then
    return nil, jitter_err
  end

  if type(jitter) ~= "number" or jitter < 0 or jitter > 1 then
    error("transaction_jitter must return a number from 0 through 1", 0)
  end

  local ceiling = math.min(
    TRANSACTION_BACKOFF_INITIAL_SECONDS * 1.5 ^ attempt,
    TRANSACTION_BACKOFF_MAX_SECONDS
  )
  local delay = jitter * ceiling

  if not within_retry_time(manager, started_at, delay) then
    return nil, retry_timeout(err)
  end

  return manager.clock:sleep(delay)
end

function SESSION_METHODS:with_transaction(callback, options)
  local state, err = check_session(self)

  if not state then
    return nil, err
  end

  if type(callback) ~= "function" then
    error("transaction callback must be a function", 2)
  end

  local manager = MANAGER_STATES[state.manager]

  if operation_timeout.current() == nil
      and (state.timeout_ms ~= nil or options and options.timeout_ms ~= nil)
  then
    local transaction_options = {}

    for key, value in pairs(options or {}) do
      if key ~= "timeout_ms" then
        transaction_options[key] = value
      end
    end

    return operation_timeout.run(manager.runtime, state.timeout_ms, options, function()
      return self:with_transaction(callback, transaction_options)
    end)
  end

  if type(manager.clock) ~= "table"
      or type(manager.clock.now) ~= "function"
      or type(manager.clock.sleep) ~= "function"
  then
    error("with_transaction requires a runtime clock adapter", 2)
  end

  local started_at = manager.clock:now()
  local retry_attempt = 0
  local previous_err

  while true do
    if previous_err ~= nil then
      local slept
      slept, err = sleep_before_transaction_retry(
        manager,
        started_at,
        retry_attempt,
        previous_err
      )

      if not slept then
        return nil, err
      end

      retry_attempt = retry_attempt + 1
    end

    local started
    started, err = self:start_transaction(options)

    if not started then
      return nil, err
    end

    local callback_ok, result, callback_err = pcall(
      operation_timeout.transaction_callback,
      callback,
      self
    )

    if not callback_ok then
      if self:is_in_transaction() then
        abort_with_refreshed_timeout(self)
      end

      if errors.is(result) then
        callback_err = result
        result = nil
      else
        error(result, 0)
      end
    end

    if callback_err ~= nil and not errors.is(callback_err) then
      if self:is_in_transaction() then
        abort_with_refreshed_timeout(self)
      end

      error("transaction callback error must be a structured error", 2)
    end

    if callback_err ~= nil then
      if self:is_in_transaction() then
        abort_with_refreshed_timeout(self)
      end

      if callback_err:has_label("TransientTransactionError")
          and within_retry_time(manager, started_at)
      then
        previous_err = callback_err
      else
        return nil, within_retry_time(manager, started_at)
          and callback_err or retry_timeout(callback_err)
      end
    elseif not self:is_in_transaction() then
      return result
    else
      while true do
        local committed
        committed, err = self:commit_transaction()

        if committed then
          return result
        end

        local retry_commit = err.code ~= 50
          and err:has_label("UnknownTransactionCommitResult")
          and within_retry_time(manager, started_at)

        if not retry_commit then
          if err:has_label("TransientTransactionError")
              and within_retry_time(manager, started_at)
          then
            previous_err = err
            break
          end

          return nil, within_retry_time(manager, started_at)
              and err or retry_timeout(err)
        end
      end
    end
  end
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
    if key ~= "causal_consistency" and key ~= "default_transaction_options"
        and key ~= "snapshot" and key ~= "snapshot_time"
        and key ~= "timeout_ms"
    then
      error("unknown session option: " .. tostring(key), 2)
    end
  end

  if options.causal_consistency ~= nil
    and type(options.causal_consistency) ~= "boolean"
  then
    error("causal_consistency must be a boolean", 2)
  end

  if options.snapshot ~= nil and type(options.snapshot) ~= "boolean" then
    error("snapshot must be a boolean", 2)
  end

  if options.snapshot and options.causal_consistency then
    error("snapshot sessions do not support causal_consistency=true", 2)
  end

  if options.snapshot_time ~= nil and not options.snapshot then
    error("snapshot_time requires snapshot=true", 2)
  end

  if options.snapshot_time ~= nil
      and not bson.is_tagged(options.snapshot_time, "timestamp")
  then
    error("snapshot_time must be a BSON timestamp", 2)
  end

  if options.timeout_ms ~= nil
      and (math.type(options.timeout_ms) ~= "integer" or options.timeout_ms < 0)
  then
    error("timeout_ms must be a non-negative integer", 2)
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
  local default_transaction_options = {}

  for key, value in pairs(manager_state.default_transaction_options) do
    default_transaction_options[key] = value
  end

  for key, value in pairs(options.default_transaction_options or {}) do
    default_transaction_options[key] = value
  end

  SESSION_STATES[session] = {
    causal_consistency = not options.snapshot
      and options.causal_consistency ~= false,
    cluster_time = nil,
    ended = false,
    manager = self,
    default_transaction_options = default_transaction_options,
    operation_time = nil,
    server_session = server_session,
    snapshot = options.snapshot == true,
    snapshot_time = options.snapshot_time,
    transaction = { state = "none" },
    timeout_ms = options.timeout_ms ~= nil
      and options.timeout_ms or manager_state.default_timeout_ms,
  }
  manager_state.active[session] = true
  return setmetatable(session, SESSION_METATABLE)
end

local function decoration_session(manager, session)
  local session_state, err = check_session(session)

  if not session_state then
    return nil, err
  end

  if session_state.manager ~= manager then
    return client_error("client session belongs to another client")
  end

  return session_state
end

local function active_decoration_transaction(session_state, transaction_control)
  local transaction = session_state.transaction

  if not transaction_control and (transaction.state == "aborted"
      or transaction.state == "committed"
      or transaction.state == "committed_empty")
  then
    transaction = { state = "none" }
    session_state.transaction = transaction
  end

  return transaction
end

local function decoration_context(command, options, session_state)
  local transaction_control = options.transaction_control == true
  local transaction = active_decoration_transaction(
    session_state,
    transaction_control
  )
  local in_transaction = transaction_active(transaction)

  if in_transaction and READ_COMMANDS[command:keys()[1]] then
    local operation_mode = read_preference_mode(options.read_preference)
    local transaction_mode = read_preference_mode(
      transaction.options.read_preference
    )

    if operation_mode ~= nil and operation_mode ~= "primary"
        or transaction_mode ~= nil and transaction_mode ~= "primary"
    then
      return client_error("read preference in a transaction must be primary")
    end
  end

  local add_causal_read_concern = session_state.causal_consistency
    and session_state.operation_time ~= nil

  return {
    add_causal_read_concern = add_causal_read_concern,
    in_transaction = in_transaction,
    replace_read_concern = not in_transaction
      and (options.read_concern ~= nil or add_causal_read_concern
        or session_state.snapshot),
    retryable_write = options.retryable_write == true,
    starting_transaction = transaction.state == "starting",
    transaction = transaction,
    transaction_control = transaction_control,
  }
end

local function copy_command_entries(command, context)
  local entries = {}

  for key, value in command:iter() do
    if key ~= "lsid" and key ~= "$clusterTime"
        and (key ~= "txnNumber" or (not context.retryable_write
          and not context.in_transaction))
        and (not context.in_transaction or context.transaction_control
          or key ~= "writeConcern")
        and (not context.in_transaction or key ~= "readConcern")
        and (key ~= "readConcern" or not context.replace_read_concern)
    then
      entries[#entries + 1] = { key, value }
    end
  end

  return entries
end

local function read_concern_with_operation_time(read_concern, session_state)
  local concern_entries = {}

  for key, value in read_concern:iter() do
    if key ~= "afterClusterTime"
        and (key ~= "level" or not session_state.snapshot)
    then
      concern_entries[#concern_entries + 1] = { key, value }
    end
  end

  if session_state.snapshot then
    concern_entries[#concern_entries + 1] = { "level", "snapshot" }

    if session_state.snapshot_time ~= nil then
      concern_entries[#concern_entries + 1] = {
        "atClusterTime",
        session_state.snapshot_time,
      }
    end
  elseif session_state.causal_consistency
      and session_state.operation_time ~= nil
  then
    concern_entries[#concern_entries + 1] = {
      "afterClusterTime",
      session_state.operation_time,
    }
  end

  return bson.document(concern_entries)
end

local function append_transaction_fields(entries, context, session_state, measurement)
  local transaction = context.transaction

  entries[#entries + 1] = {
    "txnNumber",
    bson.int64(session_state.server_session.transaction_number),
  }
  entries[#entries + 1] = { "autocommit", false }

  if context.transaction_control and transaction.recovery_token ~= nil then
    entries[#entries + 1] = {
      "recoveryToken",
      transaction.recovery_token,
    }
  end

  if not context.starting_transaction then
    return
  end

  entries[#entries + 1] = { "startTransaction", true }
  local read_concern = transaction.options.read_concern

  if read_concern ~= nil or context.add_causal_read_concern then
    entries[#entries + 1] = {
      "readConcern",
      read_concern_with_operation_time(
        read_concern or bson.document({}),
        session_state
      ),
    }
  end

  if not measurement then
    transaction.state = "in_progress"
  end
end

local function append_retryable_write_fields(entries, session_state)
  local server_session = session_state.server_session

  server_session.transaction_number = server_session.transaction_number + 1
  entries[#entries + 1] = {
    "txnNumber",
    bson.int64(server_session.transaction_number),
  }
end

local function append_cluster_time(entries, manager_state, session_state)
  local cluster_time = later_cluster_time(
    manager_state.cluster_time,
    session_state.cluster_time
  )

  if cluster_time then
    entries[#entries + 1] = { "$clusterTime", cluster_time }
  end
end

local function append_read_concern(entries, command, options, context, session_state)
  if not context.replace_read_concern then
    return
  end

  local read_concern = options.read_concern or command:get("readConcern")
    or bson.document({})

  if not bson.is_document(read_concern) then
    error("read_concern must be a BSON document", 3)
  end

  entries[#entries + 1] = {
    "readConcern",
    read_concern_with_operation_time(read_concern, session_state),
  }
end

function MANAGER_METHODS:decorate(command, options)
  if not bson.is_document(command) then
    error("session command must be a BSON document", 2)
  end

  options = options or {}
  local session_state, err = decoration_session(self, options.session)

  if not session_state then
    return nil, err
  end

  if session_state.snapshot and options.max_wire_version ~= nil
      and options.max_wire_version < 13
  then
    return client_error("Snapshot reads require MongoDB 5.0 or later")
  end

  local context
  context, err = decoration_context(command, options, session_state)

  if not context then
    return nil, err
  end

  local manager_state = MANAGER_STATES[self]
  local entries = copy_command_entries(command, context)

  entries[#entries + 1] = { "lsid", session_state.server_session.id }

  if context.in_transaction then
    append_transaction_fields(entries, context, session_state, options.measurement)
  elseif context.retryable_write then
    append_retryable_write_fields(entries, session_state)
  end

  append_cluster_time(entries, manager_state, session_state)
  append_read_concern(entries, command, options, context, session_state)
  session_state.server_session.last_used_at = now(manager_state)
  return bson.document(entries)
end

local function advance_snapshot_time(response, session)
  local session_state = SESSION_STATES[session]

  if session_state == nil or not session_state.snapshot
      or session_state.snapshot_time ~= nil
  then
    return
  end

  local cursor = response:get("cursor")
  local snapshot_time = bson.is_document(cursor)
    and cursor:get("atClusterTime") or response:get("atClusterTime")

  if bson.is_tagged(snapshot_time, "timestamp") then
    session_state.snapshot_time = snapshot_time
  end
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

  if session then
    advance_snapshot_time(response, session)

    local ok = response:get("ok")

    if bson.is_exact(ok) then
      ok = ok:to_number()
    end

    local session_state = SESSION_STATES[session]
    local recovery_token = response:get("recoveryToken")

    if ok == 1 and transaction_active(session_state.transaction)
        and bson.is_document(recovery_token)
    then
      session_state.transaction.recovery_token = recovery_token
    end
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

  if type(options.clock) ~= "table"
      or type(options.clock.now) ~= "function"
  then
    error("session manager requires a runtime clock adapter", 2)
  end

  if options.transaction_command ~= nil
      and type(options.transaction_command) ~= "function"
  then
    error("transaction_command must be a function", 2)
  end

  if options.transaction_jitter ~= nil
      and type(options.transaction_jitter) ~= "function"
  then
    error("transaction_jitter must be a function", 2)
  end

  if options.transaction_retry_timeout_seconds ~= nil
      and (type(options.transaction_retry_timeout_seconds) ~= "number"
        or options.transaction_retry_timeout_seconds <= 0)
  then
    error("transaction_retry_timeout_seconds must be positive", 2)
  end

  if options.default_transaction_options ~= nil
      and type(options.default_transaction_options) ~= "table"
  then
    error("default_transaction_options must be a table", 2)
  end

  if options.timeout_minutes ~= nil
    and (math.type(options.timeout_minutes) ~= "integer" or options.timeout_minutes < 0)
  then
    error("timeout_minutes must be a non-negative integer", 2)
  end

  if options.load_balanced ~= nil and type(options.load_balanced) ~= "boolean" then
    error("load_balanced must be a boolean", 2)
  end

  local timeout_minutes = options.timeout_minutes

  if options.load_balanced then
    timeout_minutes = nil
  end

  local manager = {}

  MANAGER_STATES[manager] = {
    active = {},
    clock = options.clock,
    closed = false,
    cluster_time = nil,
    default_transaction_options = options.default_transaction_options or {},
    default_timeout_ms = options.default_timeout_ms,
    id_factory = options.id_factory,
    load_balanced = options.load_balanced == true,
    pool = {},
    runtime = options.runtime,
    timeout_minutes = timeout_minutes,
    transaction_command = options.transaction_command,
    transaction_jitter = options.transaction_jitter or function()
      return 0
    end,
    transaction_retry_timeout_seconds =
      options.transaction_retry_timeout_seconds
        or WITH_TRANSACTION_TIMEOUT_SECONDS,
  }
  return setmetatable(manager, MANAGER_METATABLE)
end

return M
