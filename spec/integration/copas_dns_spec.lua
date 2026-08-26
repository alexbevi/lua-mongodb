local runtime = require("mongodb.runtime")

describe("Copas GSSAPI DNS capabilities", function()
  it("resolves and reverses the loopback host", function()
    local adapter = runtime.copas()
    local forward = assert(adapter.dns:resolve_host("localhost"))

    assert.is_string(forward.address)
    assert.is_not.equal("", forward.address)
    assert.is_string(forward.canonical_name)
    assert.is_not.equal("", forward.canonical_name)

    local reverse = assert(adapter.dns:resolve_address(forward.address))

    assert.is_string(reverse)
    assert.is_not.equal("", reverse)
  end)
end)
