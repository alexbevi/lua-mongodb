local errors = require("mongodb.error")
local cancellation_factory = require("mongodb.runtime.cancellation")
local runtime_contract = require("mongodb.runtime")

local M = {}

local function require_nonnegative_number(name, value, level)
  if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
    error(name .. " must be a finite non-negative number", level or 3)
  end
end

local function require_positive_integer(name, value, level)
  if math.type(value) ~= "integer" or value <= 0 then
    error(name .. " must be a positive integer", level or 3)
  end
end

local function shallow_copy(values)
  local result = {}

  for index, value in ipairs(values) do
    result[index] = value
  end

  return result
end

local TASK_METHODS = {}
local TASK_METATABLE = {
  __index = TASK_METHODS,
  __metatable = "mongodb.fake_task",
}

function TASK_METHODS:status()
  return self._status
end

local LOCK_METHODS = {}
local LOCK_METATABLE = { __index = LOCK_METHODS }

function LOCK_METHODS:is_locked()
  return self._locked
end

function LOCK_METHODS:acquire(deadline, cancellation)
  local ok, err = runtime_contract.check(self._owner, deadline, cancellation)

  if not ok then
    return nil, err
  end

  if self._locked then
    error("fake lock acquisition would block", 2)
  end

  self._locked = true
  return true
end

function LOCK_METHODS:release()
  if not self._locked then
    error("cannot release an unlocked fake lock", 2)
  end

  self._locked = false
  return true
end

local SOCKET_METHODS = {}

local function closed_socket_error()
  return errors.new({
    category = errors.CATEGORY.NETWORK,
    message = "socket is closed",
  })
end

function SOCKET_METHODS:read_some(max_bytes, deadline, cancellation)
  require_positive_integer("max_bytes", max_bytes, 2)

  local ok, err = runtime_contract.check(self._owner, deadline, cancellation)

  if not ok then
    return nil, err
  end

  if self._closed then
    return nil, closed_socket_error()
  end

  local event = self._reads[self._read_index]

  if event == nil then
    error("fake socket read script exhausted", 2)
  end

  if errors.is(event) then
    self._read_index = self._read_index + 1
    return nil, event
  end

  if type(event) ~= "string" then
    error("fake socket read events must be strings or structured errors", 2)
  end

  if #event <= max_bytes then
    self._read_index = self._read_index + 1
    return event
  end

  local result = string.sub(event, 1, max_bytes)
  self._reads[self._read_index] = string.sub(event, max_bytes + 1)
  return result
end

function SOCKET_METHODS:write_some(data, deadline, cancellation)
  if type(data) ~= "string" then
    error("socket data must be a string", 2)
  end

  local ok, err = runtime_contract.check(self._owner, deadline, cancellation)

  if not ok then
    return nil, err
  end

  if self._closed then
    return nil, closed_socket_error()
  end

  local length = math.min(#data, self._max_write or #data)
  local written = string.sub(data, 1, length)

  self._writes[#self._writes + 1] = written
  return length
end

function SOCKET_METHODS:writes()
  return shallow_copy(self._writes)
end

function SOCKET_METHODS:is_closed()
  return self._closed
end

function SOCKET_METHODS:close()
  if self._closed then
    return false
  end

  self._closed = true
  return true
end

function SOCKET_METHODS:push_read(event)
  if type(event) ~= "string" and not errors.is(event) then
    error("fake socket read events must be strings or structured errors", 2)
  end

  self._reads[#self._reads + 1] = event
end

local FAKE_METHODS = {}
local FAKE_METATABLE = { __index = FAKE_METHODS }

function FAKE_METHODS:advance(duration)
  require_nonnegative_number("duration", duration, 2)
  self._now = self._now + duration
  self._wall_time = self._wall_time + duration
  return self._now
end

function FAKE_METHODS:run_next()
  while self._task_head <= #self._task_queue do
    local task = self._task_queue[self._task_head]

    self._task_head = self._task_head + 1

    if task._status == "pending" then
      task._status = "running"

      local outcome = table.pack(pcall(
        task._function,
        table.unpack(task._arguments, 1, task._arguments.n)
      ))

      if outcome[1] then
        task._status = "completed"
        task._results = { n = outcome.n - 1 }

        for index = 2, outcome.n do
          task._results[index - 1] = outcome[index]
        end
      else
        task._status = "failed"
        task._failure = outcome[2]
      end

      return true
    end
  end

  return false
end

function FAKE_METHODS:run_all()
  local count = 0

  while self:run_next() do
    count = count + 1
  end

  return count
end

function FAKE_METHODS:queue_connect(result)
  if not errors.is(result) and getmetatable(result) ~= "mongodb.fake_socket" then
    error("connect results must be fake sockets or structured errors", 2)
  end

  self._connect_queue[#self._connect_queue + 1] = result
end

function FAKE_METHODS:queue_tls(result)
  if not errors.is(result) and getmetatable(result) ~= "mongodb.fake_socket" then
    error("TLS results must be fake sockets or structured errors", 2)
  end

  self._tls_queue[#self._tls_queue + 1] = result
end

function FAKE_METHODS:queue_entropy(bytes)
  if type(bytes) ~= "string" then
    error("entropy must be a string", 2)
  end

  self._entropy = self._entropy .. bytes
end

function FAKE_METHODS:queue_crypto(operation, result)
  local queue = self._crypto_queue[operation]

  if not queue then
    error("unknown fake crypto operation: " .. tostring(operation), 2)
  end

  if type(result) ~= "string" and not errors.is(result) then
    error("crypto results must be strings or structured errors", 2)
  end

  queue[#queue + 1] = result
end

local function new_clock(owner)
  return {
    now = function()
      return owner._now
    end,
    wall_time = function()
      return owner._wall_time
    end,
    sleep = function(_, duration, cancellation)
      require_nonnegative_number("duration", duration, 3)

      local ok, err = runtime_contract.check(owner, nil, cancellation)

      if not ok then
        return nil, err
      end

      owner:advance(duration)
      return true
    end,
  }
end

local function new_task_capability(owner)
  return {
    spawn = function(_, callback, ...)
      if type(callback) ~= "function" then
        error("task callback must be a function", 2)
      end

      local task = setmetatable({
        _arguments = table.pack(...),
        _function = callback,
        _owner = owner,
        _status = "pending",
      }, TASK_METATABLE)

      owner._task_queue[#owner._task_queue + 1] = task
      return task
    end,
    await = function(_, task)
      if getmetatable(task) ~= "mongodb.fake_task" or task._owner ~= owner then
        error("task must belong to this fake runtime", 2)
      end

      while task._status == "pending" do
        if not owner:run_next() then
          error("fake task queue stalled", 2)
        end
      end

      if task._status == "completed" then
        return table.unpack(task._results, 1, task._results.n)
      end

      if task._status == "cancelled" then
        return nil, runtime_contract.cancelled_error(task._cancel_reason)
      end

      if task._status == "failed" then
        error(task._failure, 0)
      end

      error("cannot await a running fake task", 2)
    end,
    cancel = function(_, task, reason)
      if getmetatable(task) ~= "mongodb.fake_task" or task._owner ~= owner then
        error("task must belong to this fake runtime", 2)
      end

      if task._status ~= "pending" then
        return false
      end

      if reason ~= nil and (type(reason) ~= "string" or reason == "") then
        error("task cancellation reason must be a non-empty string", 2)
      end

      task._status = "cancelled"
      task._cancel_reason = reason or "task cancelled"
      return true
    end,
  }
end

local function new_lock_capability(owner)
  return {
    new = function()
      return setmetatable({ _locked = false, _owner = owner }, LOCK_METATABLE)
    end,
  }
end

local function new_socket_capability(owner)
  return {
    new = function(_, options)
      options = options or {}

      if type(options) ~= "table" then
        error("fake socket options must be a table", 2)
      end

      local reads = shallow_copy(options.reads or {})

      if options.max_write ~= nil then
        require_positive_integer("max_write", options.max_write, 2)
      end

      return setmetatable({
        _closed = false,
        _max_write = options.max_write,
        _owner = owner,
        _read_index = 1,
        _reads = reads,
        _writes = {},
      }, {
        __index = SOCKET_METHODS,
        __metatable = "mongodb.fake_socket",
      })
    end,
    connect = function(_, host, port, options, deadline, cancellation)
      if type(host) ~= "string" or host == "" then
        error("socket host must be a non-empty string", 2)
      end

      require_positive_integer("socket port", port, 2)

      local ok, err = runtime_contract.check(owner, deadline, cancellation)

      if not ok then
        return nil, err
      end

      owner.calls.connect[#owner.calls.connect + 1] = {
        host = host,
        options = options,
        port = port,
      }

      local result = owner._connect_queue[owner._connect_head]

      if result == nil then
        error("fake connect script exhausted", 2)
      end

      owner._connect_head = owner._connect_head + 1

      if errors.is(result) then
        return nil, result
      end

      return result
    end,
  }
end

local function new_tls_capability(owner)
  return {
    wrap = function(_, socket, options, deadline, cancellation)
      if getmetatable(socket) ~= "mongodb.fake_socket" then
        error("TLS can only wrap a fake socket", 2)
      end

      local ok, err = runtime_contract.check(owner, deadline, cancellation)

      if not ok then
        return nil, err
      end

      owner.calls.tls[#owner.calls.tls + 1] = {
        options = options,
        socket = socket,
      }

      local result = owner._tls_queue[owner._tls_head]

      if result == nil then
        return socket
      end

      owner._tls_head = owner._tls_head + 1

      if errors.is(result) then
        return nil, result
      end

      return result
    end,
  }
end

local function new_entropy_capability(owner)
  return {
    bytes = function(_, count)
      require_positive_integer("entropy byte count", count, 2)

      if #owner._entropy < count then
        error("fake entropy script exhausted", 2)
      end

      local result = string.sub(owner._entropy, 1, count)

      owner._entropy = string.sub(owner._entropy, count + 1)
      return result
    end,
  }
end

local CRYPTO_OPERATIONS = {
  "md5",
  "sha1",
  "sha256",
  "hmac_sha1",
  "hmac_sha256",
  "pbkdf2_sha1",
  "pbkdf2_sha256",
}

local function crypto_call(owner, operation, ...)
  local queue = owner._crypto_queue[operation]
  local result = queue[1]

  if result == nil then
    error("fake crypto script exhausted for " .. operation, 3)
  end

  table.remove(queue, 1)
  owner.calls.crypto[#owner.calls.crypto + 1] = {
    arguments = { ... },
    operation = operation,
  }

  if errors.is(result) then
    return nil, result
  end

  return result
end

local function new_crypto_capability(owner)
  return {
    md5 = function(_, data)
      return crypto_call(owner, "md5", data)
    end,
    sha1 = function(_, data)
      return crypto_call(owner, "sha1", data)
    end,
    sha256 = function(_, data)
      return crypto_call(owner, "sha256", data)
    end,
    hmac_sha1 = function(_, key, data)
      return crypto_call(owner, "hmac_sha1", key, data)
    end,
    hmac_sha256 = function(_, key, data)
      return crypto_call(owner, "hmac_sha256", key, data)
    end,
    pbkdf2_sha1 = function(_, password, salt, iterations, length)
      return crypto_call(owner, "pbkdf2_sha1", password, salt, iterations, length)
    end,
    pbkdf2_sha256 = function(_, password, salt, iterations, length)
      return crypto_call(owner, "pbkdf2_sha256", password, salt, iterations, length)
    end,
  }
end

function M.new(options)
  options = options or {}

  if type(options) ~= "table" then
    error("fake runtime options must be a table", 2)
  end

  require_nonnegative_number("now", options.now or 0, 2)
  require_nonnegative_number("wall_time", options.wall_time or 0, 2)

  if options.entropy ~= nil and type(options.entropy) ~= "string" then
    error("entropy must be a string", 2)
  end

  if options.metadata ~= nil and type(options.metadata) ~= "table" then
    error("metadata must be a table", 2)
  end

  local fake = setmetatable({
    _connect_head = 1,
    _connect_queue = {},
    _crypto_queue = {},
    _entropy = options.entropy or "",
    _now = options.now or 0,
    _wall_time = options.wall_time or 0,
    _task_head = 1,
    _task_queue = {},
    _tls_head = 1,
    _tls_queue = {},
    calls = {
      connect = {},
      crypto = {},
      tls = {},
    },
  }, FAKE_METATABLE)

  for _, operation in ipairs(CRYPTO_OPERATIONS) do
    fake._crypto_queue[operation] = {}
  end

  fake.clock = new_clock(fake)
  fake.cancellation = { new = cancellation_factory.new }
  fake.task = new_task_capability(fake)
  fake.lock = new_lock_capability(fake)
  fake.socket = new_socket_capability(fake)
  fake.tls = new_tls_capability(fake)
  fake.entropy = new_entropy_capability(fake)
  fake.crypto = new_crypto_capability(fake)
  fake.metadata = options.metadata

  return runtime_contract.validate(fake)
end

return M
