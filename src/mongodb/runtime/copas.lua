local cancellation = require("mongodb.runtime.cancellation")
local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime")

local M = {}

local ALLOWED_OPTIONS = {
  copas = true,
  crypto = true,
  entropy = true,
  gettime = true,
  lock_poll_interval = true,
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

local function unavailable_error(name)
  return errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    message = name .. " capability is not configured for this runtime",
  })
end

local function unavailable_provider(name, operations)
  local provider = {}

  for _, operation in ipairs(operations) do
    provider[operation] = function()
      return nil, unavailable_error(name)
    end
  end

  return provider
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

local function new_task_capability(copas_future)
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

function M.new(options)
  options = options or {}
  validate_options(options)

  local copas = options.copas or require("copas")

  if type(copas._VERSION) ~= "string"
      or not string.match(copas._VERSION, "^Copas 4%.11%.") then
    error("lua-mongodb requires Copas 4.11.x", 2)
  end

  local raw_gettime = options.gettime or copas.gettime
  local raw_wall_time = options.wall_time or os.time

  if type(raw_gettime) ~= "function" then
    error("Copas gettime capability must be a function", 2)
  end


  if type(raw_wall_time) ~= "function" then
    error("wall_time capability must be a function", 2)
  end

  local poll_interval = options.lock_poll_interval or 0.05

  require_positive_number("lock_poll_interval", poll_interval, 2)

  local adapter = {}

  adapter.clock = new_clock(adapter, copas, raw_gettime, raw_wall_time)
  adapter.cancellation = { new = cancellation.new }
  adapter.task = new_task_capability(copas.future)
  adapter.lock = new_lock_capability(adapter, copas.lock, poll_interval)
  adapter.socket = options.socket or unavailable_provider("socket", { "connect" })
  adapter.tls = options.tls or unavailable_provider("TLS", { "wrap" })
  adapter.entropy = options.entropy or unavailable_provider("entropy", { "bytes" })
  adapter.crypto = options.crypto or unavailable_provider("crypto", {
    "sha1",
    "sha256",
    "hmac_sha1",
    "hmac_sha256",
    "pbkdf2_sha1",
    "pbkdf2_sha256",
  })

  return runtime_contract.validate(adapter)
end

return M
