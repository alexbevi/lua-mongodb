local M = {}

local METHODS = {}
local METATABLE = {
  __index = METHODS,
  __metatable = "mongodb.cancellation",
}

function METHODS:is_cancelled()
  return self._cancelled
end

function METHODS:reason()
  return self._reason
end

function METHODS:cancel(reason)
  if self._cancelled then
    return false
  end

  if reason ~= nil and (type(reason) ~= "string" or reason == "") then
    error("cancellation reason must be a non-empty string", 2)
  end

  self._cancelled = true
  self._reason = reason or "operation cancelled"

  for _, listener in ipairs(self._listeners) do
    if listener.active then
      listener.callback(self._reason)
    end
  end

  return true
end

function METHODS:on_cancel(callback)
  if type(callback) ~= "function" then
    error("cancellation callback must be a function", 2)
  end

  if self._cancelled then
    callback(self._reason)
    return function() end
  end

  local listener = { active = true, callback = callback }

  self._listeners[#self._listeners + 1] = listener

  return function()
    listener.active = false
  end
end

function M.new()
  return setmetatable({
    _cancelled = false,
    _listeners = {},
    _reason = nil,
  }, METATABLE)
end

return M
