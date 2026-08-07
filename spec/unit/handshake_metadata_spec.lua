local metadata = require("mongodb.handshake.metadata")

describe("handshake client metadata", function()
  it("builds immutable baseline metadata from client and runtime facts", function()
    local value = metadata.new({
      app_name = "metadata-spec",
      os = {
        architecture = "test-arch",
        name = "Test OS",
        type = "test-os",
        version = "1.0",
      },
      platform = "Lua 5.4 test-runtime",
    })

    assert.are.same({ "application", "driver", "os", "platform" }, value:keys())
    assert.are.equal("metadata-spec", value:get("application"):get("name"))
    assert.are.equal("lua-mongodb", value:get("driver"):get("name"))
    assert.are.equal("0.1.0-dev", value:get("driver"):get("version"))
    assert.are.same(
      { "type", "name", "architecture", "version" },
      value:get("os"):keys()
    )
    assert.are.equal("test-os", value:get("os"):get("type"))
    assert.are.equal("Test OS", value:get("os"):get("name"))
    assert.are.equal("test-arch", value:get("os"):get("architecture"))
    assert.are.equal("1.0", value:get("os"):get("version"))
    assert.are.equal("Lua 5.4 test-runtime", value:get("platform"))

    local fallback = metadata.new({ platform = "" })

    assert.are.same({ "driver", "os" }, fallback:keys())
    assert.are.equal("unknown", fallback:get("os"):get("type"))
    assert.has_error(function()
      value.extra = true
    end, "BSON values are immutable")
  end)
end)
