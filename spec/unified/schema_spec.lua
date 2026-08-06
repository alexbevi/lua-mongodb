local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local schema = require("mongodb.unified.schema")

describe("unified test format schema", function()
  it("reports the document path for a missing required property", function()
    local validator = assert(schema.compile(bson.document({
      { "type", "object" },
      { "required", bson.array({ "tests" }) },
    })))

    local valid = bson.document({
      { "tests", bson.array({ bson.document({}) }) },
    })
    assert.is_true(validator:validate(valid))

    local ok, err = validator:validate(bson.document({}))

    assert.is_nil(ok)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("$.tests", err.details.path)
  end)
end)
