local fake_runtime = require("mongodb.runtime.fake")
local runtime = require("mongodb.runtime")

describe("optional runtime provider contracts", function()
  it("validates the GSSAPI provider without requiring capability reporting", function()
    local adapter = fake_runtime.new()

    adapter.gssapi = { create_context = function() end }
    assert.are.equal(adapter, runtime.validate(adapter))

    adapter.gssapi.capabilities = function() return {} end
    assert.are.equal(adapter, runtime.validate(adapter))

    adapter.gssapi.capabilities = true
    assert.has_error(function()
      runtime.validate(adapter)
    end, "runtime GSSAPI provider is invalid")

    adapter.gssapi = {}
    assert.has_error(function()
      runtime.validate(adapter)
    end, "runtime GSSAPI provider is invalid")
  end)
end)
