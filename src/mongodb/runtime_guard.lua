local M = {}

local REQUIRED_VERSION = "Lua 5.4"
local MAX_INT64 = 0x7fffffffffffffff

function M.check(lua_version, max_integer)
  if lua_version ~= REQUIRED_VERSION then
    return nil, "lua-mongodb requires Lua 5.4"
  end

  if type(max_integer) ~= "number" or max_integer < MAX_INT64 then
    return nil, "lua-mongodb requires a Lua build with 64-bit lua_Integer"
  end

  return true
end

return M

