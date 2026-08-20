local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local runtime = require("mongodb.runtime")
local snappy_runtime = require("mongodb.runtime.snappy")

local PAYLOAD = "MongoDB wire compression\0MongoDB wire compression"
local VECTOR = "31604d6f6e676f4442207769726520636f6d7072657373696f6e005e1900"

local function hex_encode(value)
  return (value:gsub(".", function(byte)
    return string.format("%02x", string.byte(byte))
  end))
end

describe("Snappy runtime capability", function()
  it("matches the exact raw Snappy vector with compressor id 1", function()
    local provider = assert(snappy_runtime.load(require))
    local adapter = fake_runtime.new({
      compression = { snappy = provider },
    })
    local snappy = assert(adapter.compression.snappy)
    local compressed = assert(snappy:compress(PAYLOAD))

    assert.are.equal(1, snappy.compressor_id)
    assert.are.equal(VECTOR, hex_encode(compressed))
    assert.are.equal(PAYLOAD, assert(snappy:decompress(compressed)))
  end)

  it("reports a missing binding as unavailable", function()
    local provider = snappy_runtime.load(function(name)
      assert.are.equal("snappy", name)
      error("module not found")
    end)

    assert.is_nil(provider)
  end)

  it("registers the available binding in the default Copas runtime", function()
    local provider = assert(runtime.copas().compression.snappy)

    assert.are.equal("snappy", provider.name)
    assert.are.equal(1, provider.compressor_id)
  end)

  it("returns a structured protocol error for invalid compressed bytes", function()
    local provider = assert(snappy_runtime.load(require))
    local value, err = provider:decompress("not a Snappy stream")

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
    assert.are.equal("Snappy decompression failed", err.message)
  end)
end)
