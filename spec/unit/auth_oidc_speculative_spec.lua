local auth = require("mongodb.auth")
local bson = require("mongodb.bson")
local fake_runtime = require("mongodb.runtime.fake")

local function credentials(callback)
  return {
    mechanism = "MONGODB-OIDC",
    mechanism_properties = { OIDC_CALLBACK = callback },
    source = "$external",
  }
end

local function response(done)
  return bson.document({
    { "conversationId", 7 },
    { "payload", bson.binary("") },
    { "done", done },
    { "ok", 1 },
  })
end

describe("MONGODB-OIDC speculative authentication", function()
  it("uses a successful cached-token handshake without another SASL command", function()
    local callbacks = 0
    local identity = credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-access-token" }
    end)
    local runtime = fake_runtime.new()
    local first_connection = {
      command = function()
        return response(true)
      end,
    }

    assert.is_true(auth.authenticate(first_connection, runtime, identity))

    local speculative_connection = {
      commands = 0,
      command = function(self)
        self.commands = self.commands + 1
        return response(true)
      end,
    }
    local command = assert(auth.speculative_command(
      speculative_connection,
      identity
    ))
    local payload = assert(bson.decode(command:get("payload").data))

    assert.are.equal("saslStart", command:keys()[1])
    assert.are.equal("MONGODB-OIDC", command:get("mechanism"))
    assert.are.equal("private-access-token", payload:get("jwt"))
    assert.is_true(auth.authenticate(
      speculative_connection,
      runtime,
      identity,
      { speculative_response = response(true) }
    ))
    assert.are.equal(0, speculative_connection.commands)
    assert.are.equal(1, callbacks)
  end)

  it("does not speculate before a token has been cached", function()
    local callbacks = 0
    local identity = credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-access-token" }
    end)
    local connection = {
      commands = 0,
      command = function(self)
        self.commands = self.commands + 1
        return response(true)
      end,
    }

    assert.is_nil(auth.speculative_command(connection, identity))
    assert.are.equal(0, callbacks)
    assert.is_true(auth.authenticate(
      connection,
      fake_runtime.new(),
      identity
    ))
    assert.are.equal(1, callbacks)
    assert.are.equal(1, connection.commands)
  end)

  it("falls back with the client token after a missing or failed response", function()
    local speculative_responses = {
      nil,
      response(false),
      bson.document({ { "done", true }, { "ok", 1 } }),
    }

    for _, response_value in ipairs({
      { value = speculative_responses[1] },
      { value = speculative_responses[2] },
      { value = speculative_responses[3] },
    }) do
      local callbacks = 0
      local tokens = {}
      local identity = credentials(function()
        callbacks = callbacks + 1
        return { access_token = "private-access-token" }
      end)
      local runtime = fake_runtime.new()

      assert.is_true(auth.authenticate({
        command = function()
          return response(true)
        end,
      }, runtime, identity))

      local connection = {
        command = function(_, _, body)
          local payload = assert(bson.decode(body:get("payload").data))

          tokens[#tokens + 1] = payload:get("jwt")
          return response(true)
        end,
      }

      assert(auth.speculative_command(connection, identity))
      assert.is_true(auth.authenticate(connection, runtime, identity, {
        speculative_response = response_value.value,
      }))
      assert.are.same({ "private-access-token" }, tokens)
      assert.are.equal(1, callbacks)
    end
  end)
end)
