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

local function idp_payload(issuer)
  return assert(bson.encode(bson.document({
    { "issuer", issuer or "https://issuer.example.com" },
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

describe("MONGODB-OIDC human authentication recovery", function()
  it("retries a rejected cached access token through the refresh tier", function()
    local callbacks = 0
    local identity = credentials(function(context)
      callbacks = callbacks + 1

      if callbacks == 1 then
        assert.is_nil(context.refresh_token)
        return {
          access_token = "private-access-token-1",
          refresh_token = "private-refresh-token-1",
        }
      end

      assert.are.equal("private-refresh-token-1", context.refresh_token)
      return {
        access_token = "private-access-token-2",
        refresh_token = "private-refresh-token-2",
      }
    end)
    local runtime = fake_runtime.new()

    assert.is_true(auth.authenticate(
      two_step_connection(),
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))

    local calls = 0
    local tokens = {}
    local recovering_connection = {
      command = function(_, _, body)
        calls = calls + 1

        local payload = assert(bson.decode(body:get("payload").data))

        tokens[#tokens + 1] = payload:get("jwt")

        if calls == 1 then
          return nil, server_error(18, "private cached token rejected")
        end

        return response(true)
      end,
    }

    assert.is_true(auth.authenticate(
      recovering_connection,
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.are.same({
      "private-access-token-1",
      "private-access-token-2",
    }, tokens)
    assert.are.equal(2, callbacks)
    assert.are.equal(2, calls)
  end)

  it("starts a new two-step flow when no refresh token is cached", function()
    local callbacks = 0
    local identity = credentials(function(context)
      callbacks = callbacks + 1
      assert.is_nil(context.refresh_token)

      if callbacks == 1 then
        assert.are.equal("https://issuer.example.com", context.idp_info.issuer)
        return { access_token = "private-access-token-1" }
      end

      assert.are.equal("https://new-issuer.example.com", context.idp_info.issuer)
      return { access_token = "private-access-token-2" }
    end)
    local runtime = fake_runtime.new()

    assert.is_true(auth.authenticate(
      two_step_connection(),
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))

    local calls = 0
    local tokens = {}
    local recovering_connection = {
      command = function(_, _, body)
        calls = calls + 1
        local payload = assert(bson.decode(body:get("payload").data))

        if calls == 1 then
          tokens[#tokens + 1] = payload:get("jwt")
          return nil, server_error(18, "private cached token rejected")
        end

        if calls == 2 then
          assert.are.equal("human-user", payload:get("n"))
          return response(false, idp_payload("https://new-issuer.example.com"))
        end

        tokens[#tokens + 1] = payload:get("jwt")
        return response(true)
      end,
    }

    assert.is_true(auth.authenticate(
      recovering_connection,
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.are.same({
      "private-access-token-1",
      "private-access-token-2",
    }, tokens)
    assert.are.equal(2, callbacks)
    assert.are.equal(3, calls)
  end)

  it("clears rejected refresh state before one new two-step flow", function()
    local callbacks = 0
    local identity = credentials(function(context)
      callbacks = callbacks + 1

      if callbacks == 1 then
        assert.is_nil(context.refresh_token)
        return {
          access_token = "private-access-token-1",
          refresh_token = "private-refresh-token-1",
        }
      end

      if callbacks == 2 then
        assert.are.equal("private-refresh-token-1", context.refresh_token)
        return {
          access_token = "private-access-token-2",
          refresh_token = "private-refresh-token-2",
        }
      end

      assert.is_nil(context.refresh_token)
      assert.are.equal("https://new-issuer.example.com", context.idp_info.issuer)
      return {
        access_token = "private-access-token-3",
        refresh_token = "private-refresh-token-3",
      }
    end)
    local runtime = fake_runtime.new()
    local initial_connection = two_step_connection()

    assert.is_true(auth.authenticate(
      initial_connection,
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.is_true(oidc.invalidate(initial_connection, identity))

    local calls = 0
    local tokens = {}
    local recovering_connection = {
      command = function(_, _, body)
        calls = calls + 1
        local payload = assert(bson.decode(body:get("payload").data))

        if calls == 1 then
          tokens[#tokens + 1] = payload:get("jwt")
          return nil, server_error(18, "private refreshed token rejected")
        end

        if calls == 2 then
          assert.are.equal("human-user", payload:get("n"))
          return response(false, idp_payload("https://new-issuer.example.com"))
        end

        tokens[#tokens + 1] = payload:get("jwt")
        return response(true)
      end,
    }

    assert.is_true(auth.authenticate(
      recovering_connection,
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.are.same({
      "private-access-token-2",
      "private-access-token-3",
    }, tokens)
    assert.are.equal(3, callbacks)
    assert.are.equal(3, calls)
  end)

  it("retains refreshed credentials after a non-authentication failure", function()
    local callbacks = 0
    local identity = credentials(function(context)
      callbacks = callbacks + 1

      if callbacks == 1 then
        return {
          access_token = "private-access-token-1",
          refresh_token = "private-refresh-token-1",
        }
      end

      assert.are.equal("private-refresh-token-1", context.refresh_token)
      return {
        access_token = "private-access-token-2",
        refresh_token = "private-refresh-token-2",
      }
    end)
    local runtime = fake_runtime.new()
    local initial_connection = two_step_connection()

    assert.is_true(auth.authenticate(
      initial_connection,
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.is_true(oidc.invalidate(initial_connection, identity))

    local failed_connection = {
      command = function()
        return nil, server_error(91, "private server unavailable")
      end,
    }
    local authenticated, err = auth.authenticate(
      failed_connection,
      runtime,
      identity,
      { server_host = "login.example.com" }
    )

    assert.is_nil(authenticated)
    assert.are.equal(91, err.code)

    local token
    local succeeding_connection = {
      command = function(_, _, body)
        local payload = assert(bson.decode(body:get("payload").data))

        token = payload:get("jwt")
        return response(true)
      end,
    }

    assert.is_true(auth.authenticate(
      succeeding_connection,
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.are.equal("private-access-token-2", token)
    assert.are.equal(2, callbacks)
  end)

  it("does not retry a rejected token from the new two-step flow", function()
    local callbacks = 0
    local identity = credentials(function(context)
      callbacks = callbacks + 1

      if callbacks == 1 then
        return {
          access_token = "private-access-token-1",
          refresh_token = "private-refresh-token-1",
        }
      end

      if callbacks == 2 then
        assert.are.equal("private-refresh-token-1", context.refresh_token)
        return {
          access_token = "private-access-token-2",
          refresh_token = "private-refresh-token-2",
        }
      end

      assert.is_nil(context.refresh_token)
      return {
        access_token = "private-access-token-3",
        refresh_token = "private-refresh-token-3",
      }
    end)
    local runtime = fake_runtime.new()
    local initial_connection = two_step_connection()

    assert.is_true(auth.authenticate(
      initial_connection,
      runtime,
      identity,
      { server_host = "login.example.com" }
    ))
    assert.is_true(oidc.invalidate(initial_connection, identity))

    local calls = 0
    local recovering_connection = {
      command = function()
        calls = calls + 1

        if calls == 1 then
          return nil, server_error(18, "private refreshed token rejected")
        end

        if calls == 2 then
          return response(false, idp_payload())
        end

        return nil, server_error(18, "private new token rejected")
      end,
    }
    local authenticated, err = auth.authenticate(
      recovering_connection,
      runtime,
      identity,
      { server_host = "login.example.com" }
    )

    assert.is_nil(authenticated)
    assert.are.equal(18, err.code)
    assert.are.equal(3, callbacks)
    assert.are.equal(3, calls)
  end)
end)
