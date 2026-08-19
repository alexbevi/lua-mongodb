local M = {}

local SUPPORTED_VERSIONS = {
  ["Lua 5.4"] = true,
  ["Lua 5.5"] = true,
}
local MAX_INT64 = 0x7fffffffffffffff

function M.check(lua_version, max_integer)
  if not SUPPORTED_VERSIONS[lua_version] then
    return nil, "lua-mongodb requires Lua 5.4 or Lua 5.5"
  end

  if type(max_integer) ~= "number" or max_integer < MAX_INT64 then
    return nil, "lua-mongodb requires a Lua build with 64-bit lua_Integer"
  end

  return true
end

return M
