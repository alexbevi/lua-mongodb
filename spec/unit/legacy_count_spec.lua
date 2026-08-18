local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")
local retry_executor = require("mongodb.retry_executor")
local fake_runtime = require("mongodb.runtime.fake")

describe("legacy collection count", function()
  it("encodes the count command and returns n", function()
    local sent
    local executor = {
      close = function()
        return true
      end,
      capabilities = function()
        return { max_wire_version = 27 }
      end,
      command = function(_, database, command, options)
        sent = {
          command = command,
          database = database,
          options = options,
        }
        return bson.document({ { "ok", 1 }, { "n", bson.int64(2) } })
      end,
    }
    local config = assert(driver_options.normalize(nil, {
      read_concern = { level = "majority" },
    }))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("users"))
    local filter = bson.document({ { "kind", "active" } })
    local collation = bson.document({ { "locale", "en" } })

    assert.are.equal(2, assert(collection:count(filter, {
      collation = collation,
      comment = "legacy count",
      hint = "kind_1",
      limit = 3,
      max_time_ms = 50,
      raw_data = true,
      skip = 1,
    })))
    assert.are.equal("app", sent.database)
    assert.are.equal("count", sent.command:keys()[1])
    assert.are.equal("users", sent.command:get("count"))
    assert.are.equal(filter, sent.command:get("query"))
    assert.are.equal(collation, sent.command:get("collation"))
    assert.are.equal("legacy count", sent.command:get("comment"))
    assert.are.equal("kind_1", sent.command:get("hint"))
    assert.are.equal(3, sent.command:get("limit"))
    assert.are.equal(50, sent.command:get("maxTimeMS"))
    assert.is_true(sent.command:get("rawData"))
    assert.are.equal(1, sent.command:get("skip"))
    assert.are.equal("majority", sent.command:get("readConcern"):get("level"))
  end)

  it("retries one eligible command failure", function()
    local attempts = 0
    local underlying = {
      capabilities = function()
        return { max_wire_version = 27 }
      end,
      close = function()
        return true
      end,
      command = function()
        attempts = attempts + 1

        if attempts == 1 then
          return nil, errors.new({
            category = errors.CATEGORY.SERVER,
            code = 10107,
            message = "not writable primary",
          })
        end

        return bson.document({ { "ok", 1 }, { "n", 2 } })
      end,
    }
    local executor = retry_executor.new(underlying, { enabled_reads = true })
    local config = assert(driver_options.normalize(nil, {}))
    local collection = assert(api.new_client(executor, config)
      :database("app"):collection("users"))

    assert.are.equal(2, assert(collection:count(bson.document({}))))
    assert.are.equal(2, attempts)
  end)

  it("does not retry disabled or ineligible failures", function()
    for _, case in ipairs({
      { code = 10107, enabled = false },
      { code = 2, enabled = true },
    }) do
      local attempts = 0
      local underlying = {
        capabilities = function()
          return { max_wire_version = 27 }
        end,
        close = function()
          return true
        end,
        command = function()
          attempts = attempts + 1
          return nil, errors.new({
            category = errors.CATEGORY.SERVER,
            code = case.code,
            message = "count failed",
          })
        end,
      }
      local executor = retry_executor.new(underlying, {
        enabled_reads = case.enabled,
      })
      local config = assert(driver_options.normalize(nil, {}))
      local collection = assert(api.new_client(executor, config)
        :database("app"):collection("users"))
      local result, err = collection:count(bson.document({}))

      assert.is_nil(result)
      assert.are.equal(case.code, err.code)
      assert.are.equal(1, attempts)
    end
  end)

  it("reuses one operation deadline for a retry", function()
    local runtime = fake_runtime.new({ now = 10 })
    local deadlines = {}
    local underlying = {
      capabilities = function()
        return { max_wire_version = 27 }
      end,
      close = function()
        return true
      end,
      command = function(_, _, _, options)
        deadlines[#deadlines + 1] = options.deadline

        if #deadlines == 1 then
          runtime:advance(0.05)
          return nil, errors.new({
            category = errors.CATEGORY.NETWORK,
            message = "socket timeout",
          })
        end

        return bson.document({ { "ok", 1 }, { "n", 2 } })
      end,
    }
    local executor = retry_executor.new(underlying, { enabled_reads = true })
    local config = assert(driver_options.normalize(nil, { timeout_ms = 200 }))
    local collection = assert(api.new_client(
      executor,
      config,
      nil,
      nil,
      nil,
      nil,
      runtime
    ):database("app"):collection("users"))

    assert.are.equal(2, assert(collection:count(bson.document({}))))
    assert.same({ 10.2, 10.2 }, deadlines)
  end)
end)
