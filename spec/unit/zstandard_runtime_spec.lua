local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local runtime = require("mongodb.runtime")
local zstandard_runtime = require("mongodb.runtime.zstandard")

local PAYLOAD = "MongoDB wire compression\0MongoDB wire compression"
local VECTOR = "28b52ffd2031fd0000c84d6f6e676f4442207769726520636f6d7072657373696f6e"
  .. "0001003138c7"

local function hex_encode(value)
  return (value:gsub(".", function(byte)
    return string.format("%02x", string.byte(byte))
  end))
end

describe("Zstandard runtime capability", function()
  it("matches the exact Zstandard frame vector with compressor id 3", function()
    local provider = assert(zstandard_runtime.load(require))
    local adapter = fake_runtime.new({
      compression = { zstd = provider },
    })
    local zstd = assert(adapter.compression.zstd)
    local compressed = assert(zstd:compress(PAYLOAD))

    assert.are.equal(3, zstd.compressor_id)
    assert.are.equal(VECTOR, hex_encode(compressed))
    assert.are.equal(PAYLOAD, assert(zstd:decompress(compressed)))
  end)

  it("reports a missing binding as unavailable", function()
    local provider = zstandard_runtime.load(function(name)
      assert.are.equal("zstd", name)
      error("module not found")
    end)

    assert.is_nil(provider)
  end)

  it("registers the available binding in the default Copas runtime", function()
    local provider = assert(runtime.copas().compression.zstd)

    assert.are.equal("zstd", provider.name)
    assert.are.equal(3, provider.compressor_id)
  end)

  it("returns a structured protocol error for invalid compressed bytes", function()
    local provider = assert(zstandard_runtime.load(require))
    local value, err = provider:decompress("not a Zstandard frame")

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
    assert.are.equal("Zstandard decompression failed", err.message)
  end)
end)
