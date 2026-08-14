local auth = require("mongodb.auth")
local oidc = require("mongodb.auth.oidc")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local function credentials(callback)
  return {
    mechanism = "MONGODB-OIDC",
    mechanism_properties = {
      ALLOWED_HOSTS = { "login.example.com" },
      OIDC_HUMAN_CALLBACK = callback,
    },
    source = "$external",
    username = "human-user",
  }
end

local function idp_payload()
  return assert(bson.encode(bson.document({
    { "issuer", "https://issuer.example.com" },
  })))
end

local function response(done, payload)
  return bson.document({
    { "conversationId", 7 },
    { "payload", bson.binary(payload or "") },
    { "done", done },
    { "ok", 1 },
  })
end

local function server_error(code, message)
  return errors.new({
    category = errors.CATEGORY.SERVER,
    code = code,
    message = message,
  })
end

local function two_step_connection(tokens)
  return {
    calls = 0,
    command = function(self, _, body)
      self.calls = self.calls + 1

      if self.calls == 1 then
        assert.are.equal("saslStart", body:keys()[1])
        return response(false, idp_payload())
      end

      assert.are.equal("saslContinue", body:keys()[1])

      local payload = assert(bson.decode(body:get("payload").data))

      tokens[#tokens + 1] = payload:get("jwt")
      return response(true)
    end,
  }
end

local function one_step_connection(tokens, failure)
  return {
    calls = 0,
    command = function(self, _, body)
      self.calls = self.calls + 1
      assert.are.equal("saslStart", body:keys()[1])

      local payload = assert(bson.decode(body:get("payload").data))

      tokens[#tokens + 1] = payload:get("jwt")

      if failure then
        return nil, failure
      end

      return response(true)
    end,
  }
end

describe("MONGODB-OIDC human access-token cache", function()
  it("reuses a two-step token on a later connection", function()
    local callbacks = 0
    local identity = credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-access-token" }
    end)
    local first_calls = 0
    local first_connection = {
      command = function(_, _, body)
        first_calls = first_calls + 1

        if first_calls == 1 then
          assert.are.equal("saslStart", body:keys()[1])
          return response(false, idp_payload())
        end

        assert.are.equal("saslContinue", body:keys()[1])
        return response(true)
      end,
    }

    assert.is_true(auth.authenticate(
      first_connection,
      fake_runtime.new(),
      identity,
      { server_host = "login.example.com" }
    ))

    local second_calls = 0
    local second_connection = {
      command = function(_, _, body)
        second_calls = second_calls + 1
        assert.are.equal("saslStart", body:keys()[1])

        local payload = assert(bson.decode(body:get("payload").data))
        local jwt = payload:get("jwt")

        assert.are.equal("private-access-token", jwt)
        return response(true)
      end,
    }

    assert.is_true(auth.authenticate(
      second_connection,
      fake_runtime.new(),
      identity,
      { server_host = "login.example.com" }
    ))
    assert.are.equal(1, callbacks)
    assert.are.equal(2, first_calls)
    assert.are.equal(1, second_calls)
  end)

  it("invalidates a matching token after authentication error 18", function()
    local callbacks = 0
    local identity = credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-token-" .. callbacks }
    end)
    local runtime = fake_runtime.new()
    local tokens = {}

    assert.is_true(auth.authenticate(
      two_step_connection(tokens),
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))

    local authenticated, err = auth.authenticate(
      one_step_connection(tokens, server_error(
        18,
        "private-token-1 was rejected"
      )),
      runtime,
      identity,
      { server_host = "login.example.com" }
    )

    assert.is_nil(authenticated)
    assert.are.equal(18, err.code)
    assert.are.equal(1, callbacks)
    assert.is_nil(tostring(err):find("private", 1, true))
    assert.is_true(auth.authenticate(
      two_step_connection(tokens),
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.are.same({ "private-token-1", "private-token-1", "private-token-2" }, tokens)
    assert.are.equal(2, callbacks)
  end)

  it("retains a human token after a non-authentication failure", function()
    local callbacks = 0
    local identity = credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-access-token" }
    end)
    local runtime = fake_runtime.new()
    local tokens = {}

    assert.is_true(auth.authenticate(
      two_step_connection(tokens),
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))

    local authenticated, err = auth.authenticate(
      one_step_connection(tokens, server_error(
        91,
        "private-access-token unavailable"
      )),
      runtime,
      identity,
      { server_host = "login.example.com" }
    )

    assert.is_nil(authenticated)
    assert.are.equal(91, err.code)
    assert.is_true(auth.authenticate(
      one_step_connection(tokens),
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.are.equal(1, callbacks)
    assert.are.same({
      "private-access-token",
      "private-access-token",
      "private-access-token",
    }, tokens)
  end)

  it("does not let a stale connection invalidate a newer token", function()
    local callbacks = 0
    local identity = credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-token-" .. callbacks }
    end)
    local runtime = fake_runtime.new()
    local tokens = {}
    local stale_connection = two_step_connection(tokens)

    assert.is_true(auth.authenticate(
      stale_connection,
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.is_nil(auth.authenticate(
      one_step_connection(tokens, server_error(18, "private rejection")),
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.is_true(auth.authenticate(
      two_step_connection(tokens),
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.is_true(oidc.invalidate(stale_connection, identity))
    assert.is_true(auth.authenticate(
      one_step_connection(tokens),
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.are.equal(2, callbacks)
    assert.are.equal("private-token-2", tokens[#tokens])
  end)
end)
