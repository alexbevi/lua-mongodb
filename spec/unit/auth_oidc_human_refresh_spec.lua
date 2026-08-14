local auth = require("mongodb.auth")
local oidc = require("mongodb.auth.oidc")
local bson = require("mongodb.bson")
local copas = require("copas")
local fake_runtime = require("mongodb.runtime.fake")
local runtime_module = require("mongodb.runtime")

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
    { "clientId", "client-id" },
    { "requestScopes", bson.array({ "openid" }) },
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

local function two_step_connection()
  return {
    calls = 0,
    command = function(self)
      self.calls = self.calls + 1

      if self.calls == 1 then
        return response(false, idp_payload())
      end

      return response(true)
    end,
  }
end

local function one_step_connection(callback)
  return {
    calls = 0,
    command = function(self, _, body)
      self.calls = self.calls + 1

      local payload = assert(bson.decode(body:get("payload").data))
      local jwt = payload:get("jwt")

      assert.is_string(jwt)

      if callback then
        callback(jwt)
      end

      return response(true)
    end,
  }
end

describe("MONGODB-OIDC human refresh credentials", function()
  it("reuses cached refresh and IdP context after access invalidation", function()
    local callbacks = 0
    local identity = credentials(function(context)
      callbacks = callbacks + 1

      if callbacks == 1 then
        assert.is_nil(context.refresh_token)
        assert.are.equal(
          "https://issuer.example.com",
          context.idp_info.issuer
        )
        return {
          access_token = "private-access-token-1",
          refresh_token = "private-refresh-token",
        }
      end

      assert.are.equal("private-refresh-token", context.refresh_token)
      assert.are.equal(
        "https://issuer.example.com",
        context.idp_info.issuer
      )
      assert.are.equal("client-id", context.idp_info.client_id)
      assert.are.same({ "openid" }, context.idp_info.request_scopes)
      return { access_token = "private-access-token-2" }
    end)
    local runtime = fake_runtime.new({ now = 10 })
    local first_calls = 0
    local first_connection = {
      command = function()
        first_calls = first_calls + 1

        if first_calls == 1 then
          return response(false, idp_payload())
        end

        return response(true)
      end,
    }

    assert.is_true(auth.authenticate(
      first_connection,
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.is_true(oidc.invalidate(first_connection, identity))

    local second_calls = 0
    local second_connection = {
      command = function(_, _, body)
        second_calls = second_calls + 1
        assert.are.equal("saslStart", body:keys()[1])

        local payload = assert(bson.decode(body:get("payload").data))
        local jwt = payload:get("jwt")

        assert.are.equal("private-access-token-2", jwt)
        return response(true)
      end,
    }

    assert.is_true(auth.authenticate(
      second_connection,
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.are.equal(2, callbacks)
    assert.are.equal(2, first_calls)
    assert.are.equal(1, second_calls)
    assert.near(10.1, runtime.clock:now(), 0.000001)
  end)

  it("shares one callback result across concurrent two-step conversations", function()
    local runtime = runtime_module.copas()
    local callbacks = 0
    local identity = credentials(function()
      callbacks = callbacks + 1
      assert.is_true(runtime.clock:sleep(0.01))
      return {
        access_token = "private-access-token",
        refresh_token = "private-refresh-token",
      }
    end)
    local outcomes

    copas.loop(function()
      local first = runtime.task:spawn(function()
        return auth.authenticate(
          two_step_connection(),
          runtime,
          identity,
          { server_host = "login.example.com" }
        )
      end)
      local second = runtime.task:spawn(function()
        return auth.authenticate(
          two_step_connection(),
          runtime,
          identity,
          { server_host = "login.example.com" }
        )
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

  it("releases callback coordination before one-step SASL", function()
    local runtime = fake_runtime.new()
    local callbacks = 0
    local identity = credentials(function()
      callbacks = callbacks + 1
      return {
        access_token = "private-token-" .. callbacks,
        refresh_token = "private-refresh-token",
      }
    end)
    local initial = two_step_connection()

    assert.is_true(auth.authenticate(
      initial,
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.is_true(oidc.invalidate(initial, identity))

    local outer

    outer = one_step_connection(function(jwt)
      assert.are.equal("private-token-2", jwt)
      assert.is_true(oidc.invalidate(outer, identity))
      assert.is_true(auth.authenticate(
        one_step_connection(function(nested_jwt)
          assert.are.equal("private-token-3", nested_jwt)
        end),
        runtime,
        identity,
        { server_host = "login.example.com" }
      ))
    end)

    assert.is_true(auth.authenticate(
      outer,
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.are.equal(3, callbacks)
  end)
end)
