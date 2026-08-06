local bson = require("mongodb.bson")

local function from_hex(hex)
  return (hex:gsub("..", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

describe("exact BSON numerics", function()
  it("constructs Decimal128 without passing through Lua floating point", function()
    local decimal = bson.decimal128("123.45")

    assert.are.equal("123.45", tostring(decimal))
    assert.are.equal("39300000000000000000000000003c30", decimal:bid_hex())
    assert.are.equal(decimal, bson.decimal128_from_bid(decimal.bid))
  end)

  it("passes representative official Decimal128 BSON corpus vectors", function()
    local vectors = {
      { "180000001364000000000000000000000000000000007c00", "NaN", true },
      { "18000000136400000000000000000000000000000000fc00", "NaN", false },
      { "180000001364000000000000000000000000000000007e00", "NaN", false },
      { "180000001364000000000000000000000000000000007800", "Infinity", true },
      { "18000000136400000000000000000000000000000000f800", "-Infinity", true },
      { "180000001364000000000000000000000000000000106c00", "0", false },
      { "18000000136400dcba9876543210deadbeef00000010ec00", "-0", false },
      { "18000000136400ffffffffffffffffffffffffffff116c00", "0E+3", false },
      { "1800000013640001000000000000000000000000003e3000", "0.1", true },
      { "1800000013640000000000000000000000000000003eb000", "-0.0", true },
      { "18000000136400d0070000000000000000000000003a3000", "2.000", true },
      { "180000001364000100000000000000000000000000000000", "1E-6176", true },
      {
        "18000000136400ffffffff638e8d37c087adbe09edff5f00",
        "9.999999999999999999999999999999999E+6144",
        true,
      },
      {
        "18000000136400f2af967ed05c82de3297ff6fde3c40b000",
        "-1234567890123456789012345678901234",
        true,
      },
      { "180000001364000100000000000000000000000000fe5f00", "1E+6111", true },
      { "180000001364000500000000000000000000000000323000", "5E-7", true },
      { "180000001364000500000000000000000000000000303000", "5E-8", true },
    }

    for _, vector in ipairs(vectors) do
      local bytes = from_hex(vector[1])
      local decoded = assert(bson.decode(bytes)):get("d")

      assert.are.equal(vector[2], tostring(decoded))

      if vector[3] then
        local encoded = assert(bson.encode(bson.document({
          { "d", bson.decimal128(vector[2]) },
        })))

        assert.are.equal(bytes, encoded)
      end
    end
  end)

  it("rejects inexact, overflowing, and malformed Decimal128 strings", function()
    local invalid = {
      "1E-6177",
      "1E6145",
      "1.1111111111111111111111111111111111",
      ".13.3",
      "NaN123",
    }

    for _, input in ipairs(invalid) do
      assert.has_error(function()
        bson.decimal128(input)
      end)
    end
  end)

  it("preserves explicit integer and double wire types", function()
    local negative_zero = bson.double(-0.0)
    local document = bson.document({
      { "small_long", bson.int64(1) },
      { "forced_int", bson.int32(7) },
      { "negative_zero", negative_zero },
      { "nan", bson.double(0 / 0) },
    })
    local encoded = assert(bson.encode(document))
    local decoded = assert(bson.decode(encoded))

    assert.is_true(bson.is_exact(decoded:get("small_long"), "int64"))
    assert.is_true(bson.is_exact(decoded:get("forced_int"), "int32"))
    assert.is_true(bson.is_exact(decoded:get("negative_zero"), "double"))
    assert.are.equal(-math.huge, 1 / decoded:get("negative_zero").value)
    assert.are.equal(encoded, assert(bson.encode(decoded)))
    assert.has_error(function()
      bson.int32(2147483648)
    end, "BSON int32 value is outside its signed BSON range")
    assert.has_error(function()
      bson.int64(1.0)
    end, "BSON int64 value must be a Lua integer")
    assert.has_error(function()
      negative_zero.value = 0
    end, "BSON values are immutable")
  end)

  it("selects native integer widths without losing their values", function()
    local decoded = assert(bson.decode(assert(bson.encode(bson.document({
      { "int32", 1 },
      { "int64", 2147483648 },
      { "double", 1.0 },
    })))))

    assert.is_true(bson.is_exact(decoded:get("int32"), "int32"))
    assert.is_true(bson.is_exact(decoded:get("int64"), "int64"))
    assert.is_true(bson.is_exact(decoded:get("double"), "double"))
    assert.are.equal(1, decoded:get("int32"):to_number())
    assert.are.equal(2147483648, decoded:get("int64"):to_number())
    assert.are.equal(1.0, decoded:get("double"):to_number())
  end)
end)
