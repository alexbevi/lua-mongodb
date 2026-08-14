local bson = require("mongodb.bson")
local errors = require("mongodb.error")

describe("hardened BSON codec", function()
  it("exports only the supported document codec entry points", function()
    local codec = require("mongodb.bson.codec")
    local exports = {}

    for name in pairs(codec) do
      exports[#exports + 1] = name
    end

    table.sort(exports)
    assert.are.same({ "decode", "encode" }, exports)
  end)

  it("round trips the remaining deprecated BSON wire values", function()
    local object_id = bson.object_id("010203041011121314151617")
    local document = bson.document({
      { "undefined", bson.undefined },
      { "symbol", bson.symbol("legacy") },
      { "pointer", bson.db_pointer("archive.records", object_id) },
    })
    local decoded = assert(bson.decode(assert(bson.encode(document))))

    assert.are.equal(bson.undefined, decoded:get("undefined"))
    assert.are.equal("legacy", decoded:get("symbol").value)
    assert.are.equal("archive.records", decoded:get("pointer").namespace)
    assert.are.equal(object_id, decoded:get("pointer").object_id)
  end)

  it("enforces configurable document, value, and nesting limits", function()
    local document = bson.document({ { "value", "abc" } })
    local encoded = assert(bson.encode(document))

    assert.are.equal(encoded, assert(bson.encode(document, {
      max_document_size = #encoded,
      max_string_size = 3,
    })))

    local value, err = bson.encode(document, { max_document_size = #encoded - 1 })
    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.BSON))

    value, err = bson.encode(document, { max_string_size = 2 })
    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.BSON))

    local nested = bson.document({ { "leaf", 1 } })

    for _ = 1, 3 do
      nested = bson.document({ { "nested", nested } })
    end

    local nested_bytes = assert(bson.encode(nested))

    value, err = bson.encode(nested, { max_depth = 3 })
    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.BSON))

    value, err = bson.decode(nested_bytes, { max_depth = 3 })
    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.BSON))
  end)

  it("validates UTF-8 unless byte-preserving mode is explicit", function()
    local document = bson.document({ { "text", "\255" } })
    local encoded, err = bson.encode(document)

    assert.is_nil(encoded)
    assert.is_true(errors.is(err, errors.CATEGORY.BSON))

    encoded = assert(bson.encode(document, { validate_utf8 = false }))

    local decoded
    decoded, err = bson.decode(encoded)
    assert.is_nil(decoded)
    assert.is_true(errors.is(err, errors.CATEGORY.BSON))

    decoded = assert(bson.decode(encoded, { validate_utf8 = false }))
    assert.are.equal("\255", decoded:get("text"))
  end)

  it("returns structured errors for every truncated prefix", function()
    local document = bson.document({
      { "nested", bson.document({ { "value", "payload" } }) },
      { "array", bson.array({ true, bson.binary("bytes") }) },
    })
    local encoded = assert(bson.encode(document))

    for length = 0, #encoded - 1 do
      local ok, decoded, err = pcall(bson.decode, encoded:sub(1, length))

      assert.is_true(ok)
      assert.is_nil(decoded)
      assert.is_true(errors.is(err, errors.CATEGORY.BSON))
    end
  end)
end)
