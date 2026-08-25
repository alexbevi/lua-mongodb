local cancellation = require("mongodb.runtime.cancellation")
local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime.contract")

local M = {}

local ALLOWED_OPTIONS = {
  copas = true,
  compression = true,
  crypto = true,
  dns = true,
  dns_nameservers = true,
  dns_query_timeout = true,
  entropy = true,
  file = true,
  getpid = true,
  getenv = true,
  gettime = true,
  http = true,
  lock_poll_interval = true,
  metadata = true,
  socket = true,
  tls = true,
  wall_time = true,
}

local TASK_METHODS = {}
local TASK_METATABLE = {
  __index = TASK_METHODS,
  __metatable = "mongodb.copas_task",
}

function TASK_METHODS:status()
  if self._cancelled then
    return "cancelled"
  end

  local status = self._future:try()

  if status == false then
    return "pending"
  end

  if status == true then
    return "completed"
  end

  return "failed"
end

local LOCK_METHODS = {}
local LOCK_METATABLE = {
  __index = LOCK_METHODS,
  __metatable = "mongodb.copas_lock",
}

local METADATA_ENVIRONMENT_VARIABLES = {
  "AWS_EXECUTION_ENV",
  "AWS_LAMBDA_FUNCTION_MEMORY_SIZE",
  "AWS_LAMBDA_RUNTIME_API",
  "AWS_REGION",
  "FUNCTION_MEMORY_MB",
  "FUNCTION_NAME",
  "FUNCTION_REGION",
  "FUNCTION_TIMEOUT_SEC",
  "FUNCTIONS_WORKER_RUNTIME",
  "K_SERVICE",
  "KUBERNETES_SERVICE_HOST",
  "VERCEL",
  "VERCEL_REGION",
}

function LOCK_METHODS:is_locked()
  return self._lock.owner ~= nil
end

local function lock_error(reason)
  return errors.new({
    category = errors.CATEGORY.INTERNAL,
    message = "Copas lock failed: " .. tostring(reason),
  })
end

function LOCK_METHODS:acquire(deadline, token)
  while true do
    local ok, err = runtime_contract.check(self._runtime, deadline, token)

    if not ok then
      return nil, err
    end

    local remaining = runtime_contract.remaining(self._runtime, deadline)
    local wait_time = remaining or math.huge

    if token ~= nil then
      wait_time = math.min(wait_time, self._poll_interval)
    end

    local waited, reason = self._lock:get(wait_time)

    if waited ~= nil then
      return true
    end

    if reason ~= "timeout" then
      return nil, lock_error(reason)
    end
  end
end

function LOCK_METHODS:release()
  local ok, reason = self._lock:release()

  if not ok then
    error("Copas lock release failed: " .. tostring(reason), 2)
  end

  return true
end

local function require_nonnegative_number(name, value, level)
  if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
    error(name .. " must be a finite non-negative number", level or 3)
  end
end

local function require_positive_number(name, value, level)
  require_nonnegative_number(name, value, (level or 3) + 1)

  if value == 0 then
    error(name .. " must be greater than zero", level or 3)
  end
end

local function validate_options(options)
  if type(options) ~= "table" then
    error("Copas runtime options must be a table", 3)
  end

  for key in pairs(options) do
    if not ALLOWED_OPTIONS[key] then
      error("unknown Copas runtime option: " .. tostring(key), 3)
    end
  end
end

local function file_exists(path)
  local file = io.open(path, "rb")

  if file == nil then
    return false
  end

  file:close()
  return true
end

local function default_metadata(getenv)
  local environment = {}

  for _, name in ipairs(METADATA_ENVIRONMENT_VARIABLES) do
    local value = getenv(name)

    if value ~= nil then
      environment[name] = value
    end
  end

  return {
    environment = environment,
    files = { ["/.dockerenv"] = file_exists("/.dockerenv") },
  }
end

local function new_environment_capability(getenv)
  return {
    get = function(_, name)
      if type(name) ~= "string" or name == "" then
        error("environment variable name must be a non-empty string", 2)
      end

      local value = getenv(name)

      if value ~= nil and type(value) ~= "string" then
        error("environment provider must return a string or nil", 2)
      end

      return value
    end,
  }
end

local function file_error(message)
  return errors.new({
    category = errors.CATEGORY.NETWORK,
    message = message,
  })
end

local function new_file_capability(adapter)
  return {
    read = function(_, path, options)
      if type(path) ~= "string" or path == "" then
        error("file path must be a non-empty string", 2)
      end

      options = options or {}

      if type(options) ~= "table" then
        error("file read options must be a table", 2)
      end

      local max_bytes = options.max_bytes or 1024 * 1024

      if math.type(max_bytes) ~= "integer" or max_bytes <= 0 then
        error("maximum file size must be a positive integer", 2)
      end

      local ok, err = runtime_contract.check(
        adapter,
        options.deadline,
        options.cancellation
      )

      if not ok then
        return nil, err
      end

      local file = io.open(path, "rb")

      if file == nil then
        return nil, file_error("file read failed")
      end

      local outcome = table.pack(pcall(function()
        return file:read(max_bytes + 1) or ""
      end))

      file:close()

      if not outcome[1] or type(outcome[2]) ~= "string" then
        return nil, file_error("file read failed")
      end

      if #outcome[2] > max_bytes then
        return nil, file_error("file exceeds the configured size limit")
      end

      ok, err = runtime_contract.check(
        adapter,
        options.deadline,
        options.cancellation
      )

      if not ok then
        return nil, err
      end

      return outcome[2]
    end,
  }
end

local function require_copas(provided)
  local copas = provided or require("copas")

  if type(copas._VERSION) ~= "string"
      or not string.match(copas._VERSION, "^Copas 4%.11%.") then
    error("lua-mongodb requires Copas 4.11.x", 3)
  end

  return copas
end

local function new_process_capability(getpid)
  return {
    identity = function()
      local identity = getpid()

      if math.type(identity) ~= "integer" or identity <= 0 then
        error("getpid capability must return a positive integer", 2)
      end

      return identity
    end,
  }
end

local function new_clock(adapter, copas, raw_gettime, raw_wall_time)
  local last_now
  local clock = {}

  function clock.now()
    local now = raw_gettime()

    require_nonnegative_number("Copas clock value", now, 2)

    if last_now ~= nil and now < last_now then
      return last_now
    end

    last_now = now
    return now
  end

  function clock.wall_time()
    local now = raw_wall_time()

    require_nonnegative_number("wall clock value", now, 2)
    return now
  end

  function clock:sleep(duration, token)
    require_nonnegative_number("sleep duration", duration, 2)

    local ok, err = runtime_contract.check(adapter, nil, token)

    if not ok then
      return nil, err
    end

    local thread, is_main = coroutine.running()

    if thread == nil or is_main then
      error("Copas sleep must run inside a Copas task", 2)
    end

    local deadline = self:now() + duration
    local unsubscribe = function() end

    if token then
      unsubscribe = token:on_cancel(function()
        copas.wakeup(thread)
      end)
    end

    local outcome = table.pack(pcall(function()
      while true do
        local checked, check_err = runtime_contract.check(adapter, nil, token)

        if not checked then
          return nil, check_err
        end

        local remaining = deadline - self:now()

        if remaining <= 0 then
          return true
        end

        copas.pause(remaining)
      end
    end))

    unsubscribe()

    if not outcome[1] then
      error(outcome[2], 0)
    end

    return table.unpack(outcome, 2, outcome.n)
  end

  return clock
end

local function new_task_capability(copas_future, copas)
  local capability = {}

  function capability.spawn(_, callback, ...)
    if type(callback) ~= "function" then
      error("task callback must be a function", 2)
    end

    return setmetatable({
      _cancelled = false,
      _future = copas_future.addthread(callback, ...),
    }, TASK_METATABLE)
  end

  function capability.await(_, task)
    if getmetatable(task) ~= "mongodb.copas_task" then
      error("task must be a Copas runtime task", 2)
    end

    local outcome = table.pack(task._future:get())

    if outcome[1] then
      return table.unpack(outcome, 2, outcome.n)
    end

    if task._cancelled then
      return nil, runtime_contract.cancelled_error(task._cancel_reason)
    end

    error(outcome[2], 0)
  end

  function capability.yield_control()
    copas.pause(0)
    return true
  end

  function capability.cancel(_, task, reason)
    if getmetatable(task) ~= "mongodb.copas_task" then
      error("task must be a Copas runtime task", 2)
    end

    if reason ~= nil and (type(reason) ~= "string" or reason == "") then
      error("task cancellation reason must be a non-empty string", 2)
    end

    if not task._future:cancel() then
      return false
    end

    task._cancelled = true
    task._cancel_reason = reason or "task cancelled"
    return true
  end

  return capability
end

local function new_lock_capability(adapter, copas_lock, poll_interval)
  return {
    new = function()
      return setmetatable({
        _lock = copas_lock.new(math.huge, true),
        _poll_interval = poll_interval,
        _runtime = adapter,
      }, LOCK_METATABLE)
    end,
  }
end

local function default_compression()
  local providers = {}
  local snappy = require("mongodb.runtime.snappy").load()
  local zlib = require("mongodb.runtime.zlib").load()
  local zstandard = require("mongodb.runtime.zstandard").load()

  if snappy ~= nil then
    providers.snappy = snappy
  end

  if zlib ~= nil then
    providers.zlib = zlib
  end

  if zstandard ~= nil then
    providers.zstd = zstandard
  end

  return providers
end

function M.new(options)
  options = options or {}
  validate_options(options)

  local copas = require_copas(options.copas)

  local raw_gettime = options.gettime or copas.gettime
  local raw_getenv = options.getenv or os.getenv
  local raw_getpid = options.getpid or require("getpid")
  local raw_wall_time = options.wall_time or os.time

  if type(raw_gettime) ~= "function" then
    error("Copas gettime capability must be a function", 2)
  end

  if type(raw_getenv) ~= "function" then
    error("getenv capability must be a function", 2)
  end

  if type(raw_getpid) ~= "function" then
    error("getpid capability must be a function", 2)
  end

  if type(raw_wall_time) ~= "function" then
    error("wall_time capability must be a function", 2)
  end

  if options.metadata ~= nil and type(options.metadata) ~= "table" then
    error("metadata must be a table", 2)
  end

  local poll_interval = options.lock_poll_interval or 0.05

  require_positive_number("lock_poll_interval", poll_interval, 2)

  local adapter = {}
  local openssl

  if options.entropy == nil or options.crypto == nil then
    openssl = require("mongodb.runtime.openssl").new()
  end

  adapter.clock = new_clock(adapter, copas, raw_gettime, raw_wall_time)
  adapter.cancellation = { new = cancellation.new }
  adapter.task = new_task_capability(copas.future, copas)
  adapter.lock = new_lock_capability(adapter, copas.lock, poll_interval)
  adapter.process = new_process_capability(raw_getpid)
  adapter.environment = new_environment_capability(raw_getenv)
  adapter.dns = options.dns or require("mongodb.runtime.copas_dns").new(adapter, {
    copas = copas,
    nameservers = options.dns_nameservers,
    poll_interval = poll_interval,
    query_timeout = options.dns_query_timeout,
  })
  adapter.socket = options.socket or require("mongodb.runtime.copas_socket").new(adapter, {
    copas = copas,
    poll_interval = poll_interval,
  })
  adapter.tls = options.tls or require("mongodb.runtime.luasec").new(adapter)
  adapter.entropy = options.entropy or openssl.entropy
  adapter.crypto = options.crypto or openssl.crypto
  adapter.compression = options.compression

  if adapter.compression == nil then
    adapter.compression = default_compression()
  end

  adapter.file = options.file or new_file_capability(adapter)
  adapter.http = options.http or require("mongodb.runtime.http").new(adapter)
  adapter.metadata = options.metadata or default_metadata(raw_getenv)

  return runtime_contract.validate(adapter)
end

function M.run(callback, ...)
  if type(callback) ~= "function" then
    error("mongodb.run callback must be a function", 2)
  end

  local copas = require_copas()

  if copas.running then
    error("mongodb.run cannot own an active Copas loop", 2)
  end

  local arguments = table.pack(...)
  local outcome

  copas.loop(function()
    outcome = table.pack(pcall(callback, table.unpack(arguments, 1, arguments.n)))
  end)

  if outcome == nil then
    error("Copas loop exited before mongodb.run callback completed", 2)
  end

  if not outcome[1] then
    error(outcome[2], 0)
  end

  return table.unpack(outcome, 2, outcome.n)
end

return M
