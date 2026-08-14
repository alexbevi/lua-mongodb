local auth = require("mongodb.auth")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local function machine_credentials(callback)
  return {
    mechanism = "MONGODB-OIDC",
    mechanism_properties = { OIDC_CALLBACK = callback },
    source = "$external",
    username = "machine-user",
  }
end

local function successful_commands(callback)
  return {
    command = function(_, source, body, options)
      if callback then
        callback(source, body, options)
      end

      return bson.document({
        { "conversationId", 1 },
        { "payload", bson.binary("") },
        { "done", true },
        { "ok", 1 },
      })
    end,
  }
end

describe("MONGODB-OIDC machine authentication", function()
  it("passes callback context into a one-step SASL exchange", function()
    local context
    local runtime = fake_runtime.new({ now = 10 })
    local commands = {
      command = function(_, source, body)
        assert.are.equal("$external", source)
        assert.are.equal("saslStart", body:keys()[1])
        assert.are.equal("MONGODB-OIDC", body:get("mechanism"))

        local payload = assert(bson.decode(body:get("payload").data))

        assert.are.equal("private-access-token", payload:get("jwt"))
        return bson.document({
          { "conversationId", 1 },
          { "payload", bson.binary("") },
          { "done", true },
          { "ok", 1 },
        })
      end,
    }

    assert.is_true(auth.authenticate(commands, runtime, machine_credentials(
      function(value)
        context = value
        return { access_token = "private-access-token" }
      end
    )))
    assert.are.equal(70, context.deadline)
    assert.are.equal(60, context.timeout_seconds)
    assert.are.equal("machine-user", context.username)
    assert.are.equal(1, context.version)
    assert.has_error(function()
      context.version = 2
    end, "OIDC callback contexts are immutable")
  end)

  it("bounds the callback context by the caller deadline", function()
    local runtime = fake_runtime.new({ now = 10 })
    local cancellation = runtime.cancellation:new()
    local observed_options
    local commands = successful_commands(function(_, _, options)
      observed_options = options
    end)

    assert.is_true(auth.authenticate(
      commands,
      runtime,
      machine_credentials(function(context)
        assert.are.equal(25, context.deadline)
        assert.are.equal(15, context.timeout_seconds)
        assert.are.equal(cancellation, context.cancellation)
        return {
          access_token = "private-access-token",
          expires_in_seconds = 30,
        }
      end),
      { cancellation = cancellation, deadline = 25 }
    ))
    assert.are.equal(25, observed_options.deadline)
    assert.are.equal(cancellation, observed_options.cancellation)
  end)

  it("rejects invalid callback results without exposing values", function()
    local invalid_results = {
      false,
      "private-result",
      {},
      { access_token = false },
      { access_token = "" },
      { access_token = "private-token", expires_in_seconds = -1 },
      { access_token = "private-token", expires_in_seconds = math.huge },
    }

    for _, result in ipairs(invalid_results) do
      local authenticated, err = auth.authenticate(
        successful_commands(),
        fake_runtime.new(),
        machine_credentials(function()
          return result
        end)
      )

      assert.is_nil(authenticated)
      assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
      assert.is_nil(tostring(err):find("private", 1, true))
    end

    local authenticated, err = auth.authenticate(
      successful_commands(),
      fake_runtime.new(),
      machine_credentials(function()
        error("private callback failure")
      end)
    )

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.is_nil(tostring(err):find("private", 1, true))
  end)

  it("checks timeout and cancellation after the callback returns", function()
    local runtime = fake_runtime.new({ now = 10 })
    local commands_called = 0
    local commands = successful_commands(function()
      commands_called = commands_called + 1
    end)
    local authenticated, err = auth.authenticate(
      commands,
      runtime,
      machine_credentials(function()
        runtime:advance(16)
        return { access_token = "private-access-token" }
      end),
      { deadline = 25 }
    )

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.is_true(err.timeout)
    assert.are.equal(0, commands_called)

    runtime = fake_runtime.new()
    local cancellation = runtime.cancellation:new()
    authenticated, err = auth.authenticate(
      commands,
      runtime,
      machine_credentials(function()
        cancellation:cancel("private cancellation reason")
        return { access_token = "private-access-token" }
      end),
      { cancellation = cancellation }
    )

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.is_nil(tostring(err):find("private", 1, true))
    assert.are.equal(0, commands_called)
  end)

  it("sanitizes command failures and incomplete SASL responses", function()
    local commands = {
      command = function()
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          code = 18,
          message = "private server token",
        })
      end,
    }
    local authenticated, err = auth.authenticate(
      commands,
      fake_runtime.new(),
      machine_credentials(function()
        return { access_token = "private-access-token" }
      end)
    )

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal(18, err.code)
    assert.is_nil(tostring(err):find("private", 1, true))

    local invalid_responses = {
      {},
      bson.document({
        { "conversationId", 1 },
        { "payload", bson.binary("") },
        { "done", false },
      }),
      bson.document({
        { "conversationId", "one" },
        { "payload", bson.binary("") },
        { "done", true },
      }),
      bson.document({
        { "conversationId", 1 },
        { "payload", "private-payload" },
        { "done", true },
      }),
    }

    for _, response in ipairs(invalid_responses) do
      commands.command = function()
        return response
      end
      authenticated, err = auth.authenticate(
        commands,
        fake_runtime.new(),
        machine_credentials(function()
          return { access_token = "private-access-token" }
        end)
      )

      assert.is_nil(authenticated)
      assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
      assert.is_nil(tostring(err):find("private", 1, true))
    end
  end)
end)
