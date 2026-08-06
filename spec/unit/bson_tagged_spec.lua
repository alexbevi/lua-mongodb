local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local function to_hex(bytes)
  return (bytes:gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end))
end

describe("BSON tagged values", function()
  it("generates deterministic ObjectIds through runtime time and entropy", function()
    local runtime = fake_runtime.new({
      wall_time = 0x01020304,
      entropy = "\16\17\18\19\20\21\22\23",
    })
    local generator = assert(bson.object_id_generator(runtime))
    local first = assert(generator:new())
    local second = assert(generator:new())

    assert.are.equal("010203041011121314151617", tostring(first))
    assert.are.equal("010203041011121314151618", tostring(second))
    assert.are.equal(0x01020304, first.timestamp)
    assert.is_true(first < second)
    assert.are.equal(first, bson.object_id(tostring(first)))
  end)

  it("round trips tagged values using the pinned PyMongo byte layout", function()
    local document = bson.document({
      { "oid", bson.object_id("010203041011121314151617") },
      { "date", bson.datetime(-1) },
      { "regex", bson.regex("^a", "mi") },
      { "timestamp", bson.timestamp(0x10203040, 0x50607080) },
      { "code", bson.code("return x") },
      { "scope", bson.code("return x", bson.document({ { "x", 1 } })) },
      { "min", bson.min_key },
      { "max", bson.max_key },
      { "binary", bson.binary("\1\2", bson.BINARY_SUBTYPE.USER_DEFINED) },
      { "old_binary", bson.binary("\3\4", bson.BINARY_SUBTYPE.OLD_BINARY) },
    })
    local encoded = assert(bson.encode(document))

    assert.are.equal(
      "ab000000076f696400010203041011121314151617096461746500ffffffffffffffff"
        .. "0b7265676578005e6100696d001174696d657374616d700080706050403020100d636f"
        .. "6465000900000072657475726e2078000f73636f7065001d0000000900000072657475"
        .. "726e2078000c0000001078000100000000ff6d696e007f6d6178000562696e61727900"
        .. "02000000800102056f6c645f62696e61727900060000000202000000030400",
      to_hex(encoded)
    )

    local decoded = assert(bson.decode(encoded))

    assert.are.equal(document:get("oid"), decoded:get("oid"))
    assert.are.equal(-1, decoded:get("date").milliseconds)
    assert.are.equal("^a", decoded:get("regex").pattern)
    assert.are.equal("im", decoded:get("regex").options)
    assert.are.equal(0x10203040, decoded:get("timestamp").time)
    assert.are.equal(0x50607080, decoded:get("timestamp").increment)
    assert.are.equal("return x", decoded:get("code").source)
    assert.is_nil(decoded:get("code").scope)
    assert.are.equal(1, decoded:get("scope").scope:get("x").value)
    assert.are.equal(bson.min_key, decoded:get("min"))
    assert.are.equal(bson.max_key, decoded:get("max"))
    assert.are.equal(bson.binary("\1\2", 128), decoded:get("binary"))
    assert.are.equal(bson.binary("\3\4", 2), decoded:get("old_binary"))
  end)

  it("validates and compares tagged values without allowing mutation", function()
    assert.is_true(bson.datetime(-2) < bson.datetime(-1))
    assert.is_true(bson.timestamp(1, 2) < bson.timestamp(2, 0))
    assert.is_true(bson.timestamp(2, 0) < bson.timestamp(2, 1))
    assert.has_error(function()
      bson.timestamp(-1, 0)
    end)
    assert.has_error(function()
      bson.regex("pattern", "q")
    end, "unsupported BSON regex option: q")
    assert.has_error(function()
      bson.object_id("not-an-object-id")
    end, "ObjectId input must be a 12-byte or 24-character string")

    local datetime = bson.datetime(1)

    assert.has_error(function()
      datetime.milliseconds = 2
    end, "BSON values are immutable")
    assert.has_error(function()
      bson.BINARY_SUBTYPE.UUID = 99
    end, "BSON values are immutable")
  end)

  it("returns a structured error for malformed legacy binary framing", function()
    local bytes = string.pack("<i4", 18)
      .. "\5x\0"
      .. string.pack("<i4B", 5, bson.BINARY_SUBTYPE.OLD_BINARY)
      .. string.pack("<i4", 0)
      .. "\3\0"
    local decoded, err = bson.decode(bytes)

    assert.is_nil(decoded)
    assert.is_true(errors.is(err, errors.CATEGORY.BSON))
    assert.matches("length mismatch", err.message)
  end)
end)
