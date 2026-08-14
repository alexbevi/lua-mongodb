local auth = require("mongodb.auth")
local oidc = require("mongodb.auth.oidc")
local bson = require("mongodb.bson")
local copas = require("copas")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local runtime_module = require("mongodb.runtime")

local function successful_commands()
  return {
    command = function()
      return bson.document({
        { "conversationId", 1 },
        { "payload", bson.binary("") },
        { "done", true },
        { "ok", 1 },
      })
    end,
  }
end

local function machine_credentials(callback)
  return {
    mechanism = "MONGODB-OIDC",
    mechanism_properties = { OIDC_CALLBACK = callback },
    source = "$external",
  }
end

describe("MONGODB-OIDC callback coordination", function()
  it("serializes concurrent callbacks and reuses the first token", function()
    local runtime = runtime_module.copas()
    local callbacks = 0
    local credentials = machine_credentials(function()
      callbacks = callbacks + 1
      assert.is_true(runtime.clock:sleep(0.01))
      return { access_token = "private-access-token" }
    end)
    local outcomes

    copas.loop(function()
      local first = runtime.task:spawn(function()
        return auth.authenticate(successful_commands(), runtime, credentials)
      end)
      local second = runtime.task:spawn(function()
        return auth.authenticate(successful_commands(), runtime, credentials)
      end)

      outcomes = {
        table.pack(runtime.task:await(first)),
        table.pack(runtime.task:await(second)),
      }
    end)

    assert.is_true(outcomes[1][1])
    assert.is_true(outcomes[2][1])
    assert.are.equal(1, callbacks)
  end)

  it("separates callback starts by at least 100 milliseconds", function()
    local runtime = fake_runtime.new({ now = 10 })
    local starts = {}
    local credentials = machine_credentials(function()
      starts[#starts + 1] = runtime.clock:now()
      return { access_token = "private-access-token" }
    end)
    local first_connection = successful_commands()

    assert.is_true(auth.authenticate(first_connection, runtime, credentials))
    assert.is_true(oidc.invalidate(first_connection, credentials))
    assert.is_true(auth.authenticate(successful_commands(), runtime, credentials))
    assert.are.equal(2, #starts)
    assert.near(0.1, starts[2] - starts[1], 0.000001)
  end)

  it("honors a caller deadline while rate-limit waiting", function()
    local runtime = fake_runtime.new({ now = 10 })
    local callbacks = 0
    local credentials = machine_credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-access-token" }
    end)
    local first_connection = successful_commands()

    assert.is_true(auth.authenticate(first_connection, runtime, credentials))
    assert.is_true(oidc.invalidate(first_connection, credentials))

    local authenticated, err = auth.authenticate(
      successful_commands(),
      runtime,
      credentials,
      { deadline = 10.05 }
    )

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.is_true(err.timeout)
    assert.are.equal(1, callbacks)
    assert.near(10.05, runtime.clock:now(), 0.000001)
  end)

  it("honors cancellation while rate-limit waiting", function()
    local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
    local callbacks = 0
    local credentials = machine_credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-access-token" }
    end)
    local outcome

    copas.loop(function()
      local first_connection = successful_commands()

      assert.is_true(auth.authenticate(first_connection, runtime, credentials))
      assert.is_true(oidc.invalidate(first_connection, credentials))

      local cancellation = runtime.cancellation:new()
      local authentication = runtime.task:spawn(function()
        return auth.authenticate(
          successful_commands(),
          runtime,
          credentials,
          { cancellation = cancellation }
        )
      end)
      local cancel = runtime.task:spawn(function()
        assert.is_true(runtime.clock:sleep(0.01))
        return cancellation:cancel("private cancellation reason")
      end)

      outcome = table.pack(runtime.task:await(authentication))
      assert.is_true(runtime.task:await(cancel))
    end)

    assert.is_nil(outcome[1])
    assert.is_true(errors.is(outcome[2], errors.CATEGORY.AUTHENTICATION))
    assert.is_nil(tostring(outcome[2]):find("private", 1, true))
    assert.are.equal(1, callbacks)
  end)

  it("releases callback coordination before running SASL", function()
    local runtime = fake_runtime.new()
    local callbacks = 0
    local credentials = machine_credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-access-token" }
    end)
    local outer_connection

    outer_connection = {
      command = function()
        assert.is_true(oidc.invalidate(outer_connection, credentials))
        assert.is_true(auth.authenticate(
          successful_commands(),
          runtime,
          credentials
        ))
        return successful_commands():command()
      end,
    }

    assert.is_true(auth.authenticate(outer_connection, runtime, credentials))
    assert.are.equal(2, callbacks)
  end)
end)
