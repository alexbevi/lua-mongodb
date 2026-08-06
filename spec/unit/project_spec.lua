describe("project bootstrap", function()
  it("loads the top-level module", function()
    local mongodb = require("mongodb")

    assert.are.equal("0.1.0-dev", mongodb._VERSION)
  end)

  it("accepts the supported Lua runtime", function()
    local runtime_guard = require("mongodb.runtime_guard")

    assert.is_true(runtime_guard.check("Lua 5.4", math.maxinteger))
  end)

  it("rejects unsupported Lua versions", function()
    local runtime_guard = require("mongodb.runtime_guard")

    local ok, message = runtime_guard.check("Lua 5.3", math.maxinteger)

    assert.is_nil(ok)
    assert.matches("requires Lua 5%.4", message)
  end)

  it("rejects Lua builds without 64-bit integers", function()
    local runtime_guard = require("mongodb.runtime_guard")

    local ok, message = runtime_guard.check("Lua 5.4", 0x7fffffff)

    assert.is_nil(ok)
    assert.matches("64%-bit lua_Integer", message)
  end)
end)
