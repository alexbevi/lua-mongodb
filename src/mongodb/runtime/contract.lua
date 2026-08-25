local errors = require("mongodb.error")

local M = {}

local REQUIRED_CAPABILITIES = {
  "clock.now",
  "clock.sleep",
  "clock.wall_time",
  "cancellation.new",
  "task.spawn",
  "task.await",
  "task.cancel",
  "lock.new",
  "process.identity",
  "environment.get",
  "file.read",
  "http.request",
  "dns.resolve_srv",
  "dns.resolve_txt",
  "socket.connect",
  "tls.wrap",
  "entropy.bytes",
  "crypto.md5",
  "crypto.sha1",
  "crypto.sha256",
  "crypto.hmac_sha1",
  "crypto.hmac_sha256",
  "crypto.pbkdf2_sha1",
  "crypto.pbkdf2_sha256",
}

local function require_nonnegative_number(name, value)
  if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
    error(name .. " must be a finite non-negative number", 3)
  end
end

local function capability(runtime, path)
  local value = runtime

  for name in string.gmatch(path, "[^.]+") do
    if type(value) ~= "table" then
      return nil
    end

    value = value[name]
  end

  return value
end

local function validate_compression(runtime)
  if runtime.compression == nil then
    return
  end

  if type(runtime.compression) ~= "table" then
    error("runtime compression capabilities must be a table", 3)
  end

  local compressor_ids = {}

  for name, provider in pairs(runtime.compression) do
    if type(name) ~= "string" or name == "" or type(provider) ~= "table" then
      error("runtime compression providers must use non-empty string names", 3)
    end

    if provider.name ~= name
        or math.type(provider.compressor_id) ~= "integer"
        or provider.compressor_id < 1
        or provider.compressor_id > 255
        or type(provider.compress) ~= "function"
        or type(provider.decompress) ~= "function" then
      error("runtime compression provider " .. name .. " is invalid", 3)
    end

    if compressor_ids[provider.compressor_id] then
      error("runtime compression provider ids must be unique", 3)
    end

    compressor_ids[provider.compressor_id] = true
  end
end

function M.validate(runtime)
  if type(runtime) ~= "table" then
    error("runtime must be a table", 2)
  end

  for _, path in ipairs(REQUIRED_CAPABILITIES) do
    if type(capability(runtime, path)) ~= "function" then
      error("runtime capability " .. path .. " must be a function", 2)
    end
  end

  if runtime.metadata ~= nil and type(runtime.metadata) ~= "table" then
    error("runtime metadata facts must be a table", 2)
  end

  validate_compression(runtime)

  return runtime
end

function M.required_capabilities()
  local result = {}

  for index, path in ipairs(REQUIRED_CAPABILITIES) do
    result[index] = path
  end

  return result
end

function M.deadline_after(runtime, duration)
  require_nonnegative_number("duration", duration)
  return runtime.clock:now() + duration
end

function M.remaining(runtime, deadline)
  if deadline == nil then
    return nil
  end

  require_nonnegative_number("deadline", deadline)
  return math.max(deadline - runtime.clock:now(), 0)
end

function M.cancelled_error(reason)
  return errors.new({
    category = errors.CATEGORY.CANCELLED,
    message = reason or "operation cancelled",
  })
end

function M.timeout_error()
  return errors.new({
    category = errors.CATEGORY.TIMEOUT,
    message = "operation deadline expired",
  })
end

function M.check(runtime, deadline, cancellation)
  if cancellation ~= nil then
    if type(cancellation) ~= "table" or type(cancellation.is_cancelled) ~= "function" then
      error("cancellation must be a runtime cancellation token", 2)
    end

    if cancellation:is_cancelled() then
      return nil, M.cancelled_error(cancellation:reason())
    end
  end

  if deadline ~= nil then
    require_nonnegative_number("deadline", deadline)

    if runtime.clock:now() >= deadline then
      return nil, M.timeout_error()
    end
  end

  return true
end

return M
