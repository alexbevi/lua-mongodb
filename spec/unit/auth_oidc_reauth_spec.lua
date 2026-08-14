local auth = require("mongodb.auth")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local retry_executor = require("mongodb.retry_executor")

local function sasl_success()
  return bson.document({
    { "conversationId", 7 },
    { "payload", bson.binary("") },
    { "done", true },
    { "ok", 1 },
  })
end

describe("MONGODB-OIDC reauthentication", function()
  it("reauthenticates code 391 and retries the operation exactly once", function()
    local callbacks = 0
    local commands = {}
    local operation_calls = 0
    local runtime = fake_runtime.new()
    local credentials = {
      mechanism = "MONGODB-OIDC",
      mechanism_properties = {
        OIDC_CALLBACK = function()
          callbacks = callbacks + 1
          return { access_token = "private-token-" .. callbacks }
        end,
      },
      source = "$external",
    }
    local connection = {}

    function connection.command(_, _, command)
      local name = command:keys()[1]

      commands[#commands + 1] = name

      if name == "saslStart" then
        return sasl_success()
      end

      operation_calls = operation_calls + 1

      if operation_calls == 1 then
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          code = 391,
          message = "reauthentication required",
        })
      end

      return bson.document({ { "ok", 1 } })
    end

    function connection.close()
      return true
    end

    assert.is_true(auth.authenticate(connection, runtime, credentials))

    local executor = retry_executor.new(connection, {
      enabled = false,
      reauthenticate = function(options)
        assert.is_true(auth.invalidate(connection, credentials))
        return auth.authenticate(connection, runtime, credentials, options)
      end,
    })

    assert(executor:command(
      "db",
      bson.document({ { "find", "items" } }),
      { cancellation = runtime.cancellation:new() }
    ))
    assert.same({ "saslStart", "find", "saslStart", "find" }, commands)
    assert.are.equal(2, callbacks)
    assert.are.equal(2, operation_calls)
  end)

  it("surfaces reauthentication and retried-operation failures", function()
    local required = errors.new({
      category = errors.CATEGORY.SERVER,
      code = 391,
      message = "reauthentication required",
    })
    local auth_failure = errors.new({
      category = errors.CATEGORY.AUTHENTICATION,
      message = "OIDC reauthentication failed",
    })
    local commands = 0
    local reauthentications = 0
    local connection = {
      close = function() return true end,
      command = function()
        commands = commands + 1
        return nil, required
      end,
    }
    local executor = retry_executor.new(connection, {
      enabled = false,
      reauthenticate = function()
        reauthentications = reauthentications + 1
        return true
      end,
    })
    local response, err = executor:command(
      "db",
      bson.document({ { "find", "items" } })
    )

    assert.is_nil(response)
    assert.are.equal(required, err)
    assert.are.equal(2, commands)
    assert.are.equal(1, reauthentications)

    commands = 0
    reauthentications = 0
    executor = retry_executor.new(connection, {
      enabled = false,
      reauthenticate = function()
        reauthentications = reauthentications + 1
        return nil, auth_failure
      end,
    })
    response, err = executor:command(
      "db",
      bson.document({ { "insert", "items" } })
    )

    assert.is_nil(response)
    assert.are.equal(auth_failure, err)
    assert.are.equal(1, commands)
    assert.are.equal(1, reauthentications)
  end)
end)
