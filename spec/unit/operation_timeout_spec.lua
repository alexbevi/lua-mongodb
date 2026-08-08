local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local operation_timeout = require("mongodb.operation_timeout")
local fake_runtime = require("mongodb.runtime.fake")

describe("client-side operation timeout", function()
  it("keeps one nested deadline and derives a server time budget", function()
    local runtime = fake_runtime.new({ now = 4 })

    operation_timeout.run(runtime, 100, {}, function(options)
      runtime:advance(0.010)

      operation_timeout.run(runtime, 100, {}, function(nested)
        assert.are.equal(options.deadline, nested.deadline)

        local command = assert(operation_timeout.prepare_command(
          bson.document({
            { "find", "items" },
            { "writeConcern", bson.document({
              { "w", "majority" },
              { "wtimeout", 25 },
            }) },
          }),
          5
        ))

        local max_time_ms = command:get("maxTimeMS"):to_number()

        assert.is_true(max_time_ms >= 84)
        assert.is_true(max_time_ms <= 85)
        assert.are.equal("majority", command:get("writeConcern"):get("w"))
        assert.is_nil(command:get("writeConcern"):get("wtimeout"))
      end)
    end)
  end)

  it("turns deadline and server max-time failures into CSOT errors", function()
    local runtime = fake_runtime.new({ now = 1 })
    local cause = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 50,
      message = "execution time limit exceeded",
    })
    local result, err = operation_timeout.run(runtime, 10, {}, function()
      return nil, cause
    end)

    assert.is_nil(result)
    assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))
    assert.are.equal(cause, err.cause)
    assert.matches("execution time limit exceeded", tostring(err), nil, true)
  end)

  it("omits a write concern emptied by legacy timeout removal", function()
    local runtime = fake_runtime.new({ now = 1 })

    operation_timeout.run(runtime, 100, {}, function()
      local command = assert(operation_timeout.prepare_command(
        bson.document({
          { "insert", "items" },
          { "writeConcern", bson.document({ { "wtimeout", 25 } }) },
        }),
        0
      ))

      assert.is_nil(command:get("writeConcern"))
    end)
  end)

  it("does not derive maxTimeMS for getMore", function()
    local runtime = fake_runtime.new({ now = 1 })

    operation_timeout.run(runtime, 10, {}, function()
      local command = assert(operation_timeout.prepare_command(
        bson.document({ { "getMore", bson.int64(1) } }),
        0
      ))

      assert.is_nil(command:get("maxTimeMS"))
    end)
  end)
end)
