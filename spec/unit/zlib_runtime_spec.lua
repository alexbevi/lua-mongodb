local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local zlib_runtime = require("mongodb.runtime.zlib")

local PAYLOAD = "MongoDB wire compression\0MongoDB wire compression"

local VECTORS = {
  [-1] = "789cf3cdcf4bcf77715228cf2c4a5548cecf2d284a2d2ececccf63f0c5210100c1db125f",
  [0] = "7801013100ceff4d6f6e676f4442207769726520636f6d7072657373696f6e00"
    .. "4d6f6e676f4442207769726520636f6d7072657373696f6ec1db125f",
  [1] = "7801f3cdcf4bcf77715228cf2c4a5548cecf2d284a2d2ececccf63f0c5210100c1db125f",
  [2] = "785ef3cdcf4bcf77715228cf2c4a5548cecf2d284a2d2ececccf63f0c5210100c1db125f",
  [3] = "785ef3cdcf4bcf77715228cf2c4a5548cecf2d284a2d2ececccf63f0c5210100c1db125f",
  [4] = "785ef3cdcf4bcf77715228cf2c4a5548cecf2d284a2d2ececccf63f0c5210100c1db125f",
  [5] = "785ef3cdcf4bcf77715228cf2c4a5548cecf2d284a2d2ececccf63f0c5210100c1db125f",
  [6] = "789cf3cdcf4bcf77715228cf2c4a5548cecf2d284a2d2ececccf63f0c5210100c1db125f",
  [7] = "78daf3cdcf4bcf77715228cf2c4a5548cecf2d284a2d2ececccf63f0c5210100c1db125f",
  [8] = "78daf3cdcf4bcf77715228cf2c4a5548cecf2d284a2d2ececccf63f0c5210100c1db125f",
  [9] = "78daf3cdcf4bcf77715228cf2c4a5548cecf2d284a2d2ececccf63f0c5210100c1db125f",
}

local function hex_encode(value)
  return (value:gsub(".", function(byte)
    return string.format("%02x", string.byte(byte))
  end))
end

describe("zlib runtime capability", function()
  it("matches exact vectors for every supported compression level", function()
    local provider = assert(zlib_runtime.load(require))
    local runtime = fake_runtime.new({
      compression = { zlib = provider },
    })
    local zlib = assert(runtime.compression.zlib)

    assert.are.equal(2, zlib.compressor_id)

    for level = -1, 9 do
      local compressed = assert(zlib:compress(PAYLOAD, level))

      assert.are.equal(VECTORS[level], hex_encode(compressed), "level " .. level)
      assert.are.equal(PAYLOAD, assert(zlib:decompress(compressed)))
    end
  end)

  it("reports a missing provider as unavailable", function()
    local provider = zlib_runtime.load(function(name)
      assert.are.equal("zlib", name)
      error("module not found")
    end)

    assert.is_nil(provider)
  end)

  it("returns a structured protocol error for invalid compressed bytes", function()
    local provider = assert(zlib_runtime.load(require))
    local value, err = provider:decompress("not a zlib stream")

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
    assert.are.equal("zlib decompression failed", err.message)
  end)
end)
