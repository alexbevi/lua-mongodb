local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local function to_hex(bytes)
  return (bytes:gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end))
end

describe("BSON primitive codec", function()
  it("round trips ordered documents and unambiguous primitive values", function()
    local document = bson.document({
      { "string", "hello" },
      { "array", bson.array({ bson.null, true, false, 42, 2147483648, 1.25 }) },
      { "binary", bson.binary("\0\255") },
    })

    local encoded, encode_error = bson.encode(document)
    assert.is_nil(encode_error)
    assert.are.equal(
      "5a00000002737472696e67000600000068656c6c6f00046172726179002d000000"
        .. "0a300008310001083200001033002a000000123400000000800000000001350000"
        .. "0000000000f43f000562696e61727900020000000000ff00",
      to_hex(encoded)
    )

    local decoded, decode_error = bson.decode(encoded)
    assert.is_nil(decode_error)
    assert.are.same({ "string", "array", "binary" }, decoded:keys())
    assert.are.equal("hello", decoded:get("string"))

    local array = decoded:get("array")
    assert.is_true(bson.is_array(array))
    assert.is_true(bson.is_null(array:get(1)))
    assert.is_true(array:get(2))
    assert.is_false(array:get(3))
    assert.are.equal(42, array:get(4).value)
    assert.are.equal(2147483648, array:get(5).value)
    assert.are.equal(1.25, array:get(6).value)

    local binary = decoded:get("binary")
    assert.is_true(bson.is_binary(binary))
    assert.are.equal("\0\255", binary.data)
    assert.are.equal(0, binary.subtype)
    assert.are.equal(encoded, assert(bson.encode(decoded)))
  end)

  it("returns structured BSON errors for malformed declared lengths", function()
    local cases = {
      "\4\0\0\0\0",
      "\10\0\0\0\0",
      "\5\0\0\0\1",
      string.pack("<i4", 12) .. "\2x\0" .. string.pack("<i4", 100) .. "\0",
    }

    for _, bytes in ipairs(cases) do
      local value, err = bson.decode(bytes)

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.BSON))
      assert.is_truthy(err.details.offset)
    end
  end)

  it("copies immutable containers while preserving duplicate field order", function()
    local entries = {
      { "value", 1 },
      { "value", 2 },
    }
    local document = bson.document(entries)

    entries[1][1] = "changed"

    assert.are.same({ "value", "value" }, document:keys())
    assert.are.equal(2, document:get("value"))
    assert.has_error(function()
      document.extra = true
    end, "BSON values are immutable")

    local decoded = assert(bson.decode(assert(bson.encode(document))))
    assert.are.same({ "value", "value" }, decoded:keys())
  end)

  it("returns an operational error for ambiguous Lua tables", function()
    local encoded, err = bson.encode(bson.document({
      { "ambiguous", {} },
    }))

    assert.is_nil(encoded)
    assert.is_true(errors.is(err, errors.CATEGORY.BSON))
    assert.are.equal("table", err.details.lua_type)
  end)

  it("preserves the full signed Lua integer range", function()
    local document = bson.document({
      { "int32_min", -2147483648 },
      { "int64_negative", -2147483649 },
      { "int64_min", math.mininteger },
      { "int64_max", math.maxinteger },
    })
    local decoded = assert(bson.decode(assert(bson.encode(document))))

    assert.are.equal(-2147483648, decoded:get("int32_min").value)
    assert.are.equal(-2147483649, decoded:get("int64_negative").value)
    assert.are.equal(math.mininteger, decoded:get("int64_min").value)
    assert.are.equal(math.maxinteger, decoded:get("int64_max").value)
  end)
end)
