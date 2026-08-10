local M = {}

local STATES = setmetatable({}, { __mode = "k" })
local METHODS = {}
local METATABLE = { __index = METHODS }

function METHODS:track(kind, value, is_active)
  local state = STATES[self]

  if not state.known[kind] then
    error("unknown resource kind: " .. tostring(kind), 2)
  end

  if type(is_active) ~= "function" then
    error("resource activity predicate must be a function", 2)
  end

  state.resources[#state.resources + 1] = {
    is_active = is_active,
    kind = kind,
    value = value,
  }
  return value
end

function METHODS:snapshot()
  local state = STATES[self]
  local counts = {}

  for _, kind in ipairs(state.kinds) do
    counts[kind] = 0
  end

  for _, resource in ipairs(state.resources) do
    if resource.is_active(resource.value) then
      counts[resource.kind] = counts[resource.kind] + 1
    end
  end

  return counts
end

function M.new(kinds)
  if type(kinds) ~= "table" then
    error("resource kinds must be an array", 2)
  end

  local audit = {}
  local copied = {}
  local known = {}

  for index = 1, #kinds do
    local kind = kinds[index]

    if type(kind) ~= "string" or kind == "" then
      error("resource kinds must be non-empty strings", 2)
    elseif known[kind] then
      error("resource kinds must be unique", 2)
    end

    copied[index] = kind
    known[kind] = true
  end

  for key in pairs(kinds) do
    if math.type(key) ~= "integer" or key < 1 or key > #kinds then
      error("resource kinds must be an array", 2)
    end
  end

  STATES[audit] = {
    kinds = copied,
    known = known,
    resources = {},
  }
  return setmetatable(audit, METATABLE)
end

return M
