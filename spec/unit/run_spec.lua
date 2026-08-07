local mongodb = require("mongodb")

describe("default runtime runner", function()
  it("executes a callback in Copas and preserves all return values", function()
    local first, second, third = mongodb.run(function()
      local thread, is_main = coroutine.running()

      assert.is_not_nil(thread)
      assert.is_false(is_main)
      return "result", nil, 42
    end)

    assert.are.equal("result", first)
    assert.is_nil(second)
    assert.are.equal(42, third)
  end)

  it("propagates callback errors without scheduler wrapping", function()
    assert.has_error(function()
      mongodb.run(function()
        error("runner callback failed", 0)
      end)
    end, "runner callback failed")
  end)

  it("rejects programmer misuse and reentrant loop ownership", function()
    assert.has_error(function()
      mongodb.run("not a callback")
    end, "mongodb.run callback must be a function")

    mongodb.run(function()
      assert.has_error(function()
        mongodb.run(function() end)
      end, "mongodb.run cannot own an active Copas loop")
    end)
  end)
end)
