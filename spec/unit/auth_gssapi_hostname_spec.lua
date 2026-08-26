local gssapi = require("mongodb.auth.gssapi")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local function credential(mode, service_host)
  local properties = { CANONICALIZE_HOST_NAME = mode }

  if service_host ~= nil then
    properties.SERVICE_HOST = service_host
  end

  return { mechanism_properties = properties }
end

describe("GSSAPI service host canonicalization", function()
  it("uses the selected or configured host unchanged in none mode", function()
    local runtime = fake_runtime.new()

    assert.are.equal("Selected.EXAMPLE.com", assert(gssapi.service_host(
      runtime,
      credential("none"),
      "Selected.EXAMPLE.com"
    )))
    assert.are.equal("Override.EXAMPLE.com", assert(gssapi.service_host(
      runtime,
      credential("none", "Override.EXAMPLE.com"),
      "Selected.EXAMPLE.com"
    )))
    assert.are.same({}, runtime.calls.dns)
  end)

  it("lowercases forward and reverse canonical names", function()
    local runtime = fake_runtime.new()

    runtime:queue_dns("host", {
      address = "192.0.2.10",
      canonical_name = "Forward.EXAMPLE.com",
    })
    assert.are.equal("forward.example.com", assert(gssapi.service_host(
      runtime,
      credential("forward", "Alias.EXAMPLE.com"),
      "selected.example.com"
    )))
    assert.are.same({
      name = "Alias.EXAMPLE.com",
      type = "host",
    }, runtime.calls.dns[1])

    runtime:queue_dns("host", {
      address = "192.0.2.11",
      canonical_name = "Forward.EXAMPLE.com",
    })
    runtime:queue_dns("reverse", "Reverse.EXAMPLE.com")
    assert.are.equal("reverse.example.com", assert(gssapi.service_host(
      runtime,
      credential("forwardAndReverse"),
      "Selected.EXAMPLE.com"
    )))
    assert.are.same({
      name = "192.0.2.11",
      type = "reverse",
    }, runtime.calls.dns[3])

    runtime:queue_dns("host", {
      address = "192.0.2.12",
      canonical_name = "Selected.EXAMPLE.com",
    })
    runtime:queue_dns("reverse", "Same-Name-Reverse.EXAMPLE.com")
    assert.are.equal("same-name-reverse.example.com", assert(gssapi.service_host(
      runtime,
      credential("forwardAndReverse"),
      "selected.example.com"
    )))
  end)

  it("falls back to the provided host after ordinary lookup failures", function()
    local runtime = fake_runtime.new()
    local network_err = errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "lookup failed",
    })

    runtime:queue_dns("host", network_err)
    assert.are.equal("Selected.EXAMPLE.com", assert(gssapi.service_host(
      runtime,
      credential("forward"),
      "Selected.EXAMPLE.com"
    )))

    runtime:queue_dns("host", {
      address = "192.0.2.12",
      canonical_name = "Forward.EXAMPLE.com",
    })
    runtime:queue_dns("reverse", network_err)
    assert.are.equal("Selected.EXAMPLE.com", assert(gssapi.service_host(
      runtime,
      credential("forwardAndReverse"),
      "Selected.EXAMPLE.com"
    )))
  end)

  it("returns cancellation and timeout instead of falling back", function()
    local runtime = fake_runtime.new({ now = 5 })
    local token = runtime.cancellation:new()

    token:cancel("stop canonicalization")
    local host, err = gssapi.service_host(
      runtime,
      credential("forward"),
      "selected.example.com",
      nil,
      token
    )

    assert.is_nil(host)
    assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))

    host, err = gssapi.service_host(
      runtime,
      credential("forward"),
      "selected.example.com",
      5
    )

    assert.is_nil(host)
    assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))
  end)
end)
