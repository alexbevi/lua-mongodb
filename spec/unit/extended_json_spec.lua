local bson = require("mongodb.bson")
local errors = require("mongodb.error")

describe("ordered JSON and Extended JSON", function()
  it("preserves object order while converting canonical numeric wrappers", function()
    local document = assert(bson.json.decode(
      '{"second":{"$numberLong":"1"},"first":{"$numberInt":"2"}}'
    ))

    assert.are.same({ "second", "first" }, document:keys())
    assert.is_true(bson.is_exact(document:get("second"), "int64"))
    assert.is_true(bson.is_exact(document:get("first"), "int32"))
    assert.are.equal(
      '{"second":{"$numberLong":"1"},"first":{"$numberInt":"2"}}',
      assert(bson.json.encode(document, { mode = "canonical" }))
    )
  end)

  it("parses ordered JSON strings, arrays, escapes, and relaxed numbers", function()
    local document = assert(bson.json.decode(
      '{"unicode":"\\uD834\\uDD1E","array":[null,true,false,-0.5]}'
    ))

    assert.are.same({ "unicode", "array" }, document:keys())
    assert.are.equal("\240\157\132\158", document:get("unicode"))

    local array = document:get("array")
    assert.is_true(bson.is_null(array:get(1)))
    assert.is_true(array:get(2))
    assert.is_false(array:get(3))
    assert.are.equal(-0.5, array:get(4).value)
  end)

  it("writes relaxed values and canonical special doubles", function()
    local document = bson.document({
      { "integer", bson.int64(1) },
      { "double", bson.double(-0.0) },
      { "date", bson.datetime(0) },
      { "infinity", bson.double(math.huge) },
    })

    assert.are.equal(
      '{"integer":1,"double":-0.0,"date":{"$date":"1970-01-01T00:00:00.000Z"},'
        .. '"infinity":{"$numberDouble":"Infinity"}}',
      assert(bson.json.encode(document, { mode = "relaxed" }))
    )
  end)

  it("returns structured errors for malformed or over-limit JSON", function()
    local cases = {
      "",
      "[1,]",
      '"\\uD800"',
      "01",
      "{} trailing",
      '{"$numberInt":"1","extra":true}',
    }

    for _, input in ipairs(cases) do
      local decoded, err = bson.json.decode(input)

      assert.is_nil(decoded)
      assert.is_true(errors.is(err, errors.CATEGORY.BSON))
    end

    local decoded, err = bson.json.decode("[[[]]]", { max_depth = 2 })
    assert.is_nil(decoded)
    assert.is_true(errors.is(err, errors.CATEGORY.BSON))

    decoded, err = bson.json.decode('"long"', { max_string_size = 3 })
    assert.is_nil(decoded)
    assert.is_true(errors.is(err, errors.CATEGORY.BSON))

    local encoded
    encoded, err = bson.json.encode("long", { max_string_size = 3 })
    assert.is_nil(encoded)
    assert.is_true(errors.is(err, errors.CATEGORY.BSON))
  end)

  it("preserves precise errors for recognized malformed wrappers", function()
    local cases = {
      {
        '{"$numberInt":"1","extra":true}',
        "invalid $numberInt wrapper fields",
      },
      { '{"$numberDouble":1}', "invalid $numberDouble wrapper" },
      {
        '{"$numberDecimal":"not-a-decimal"}',
        "invalid $numberDecimal value",
      },
      {
        '{"$binary":{"base64":"","subType":"0"}}',
        "invalid $binary value",
      },
      { '{"$date":"not-a-date"}', "invalid $date value" },
      {
        '{"$regularExpression":{"pattern":"x"}}',
        "invalid $regularExpression value",
      },
      {
        '{"$timestamp":{"t":1,"i":"1"}}',
        "invalid $timestamp value",
      },
      { '{"$code":"return 1","extra":true}', "invalid $code wrapper" },
      { '{"$minKey":0}', "invalid $minKey wrapper" },
      { '{"$undefined":false}', "invalid $undefined wrapper" },
      { '{"$symbol":1}', "invalid $symbol wrapper" },
      {
        '{"$dbPointer":{"$ref":"items","$id":"not-an-object-id"}}',
        "invalid $dbPointer value",
      },
    }

    for _, case in ipairs(cases) do
      local decoded, err = bson.json.decode(case[1])

      assert.is_nil(decoded)
      assert.is_true(errors.is(err, errors.CATEGORY.BSON))
      assert.are.equal(case[2], err.message)
      assert.are.equal(1, err.details.offset)
    end
  end)
end)
