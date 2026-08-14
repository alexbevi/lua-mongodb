local auth = require("mongodb.auth")
local oidc = require("mongodb.auth.oidc")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local function success_response()
  return bson.document({
    { "conversationId", 1 },
    { "payload", bson.binary("") },
    { "done", true },
    { "ok", 1 },
  })
end

local function successful_commands(tokens)
  return {
    command = function(_, _, body)
      local payload = assert(bson.decode(body:get("payload").data))

      tokens[#tokens + 1] = payload:get("jwt")
      return success_response()
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

local function server_error(code, message)
  return errors.new({
    category = errors.CATEGORY.SERVER,
    code = code,
    message = message,
  })
end

describe("MONGODB-OIDC machine token cache", function()
  it("reuses one callback token across connections", function()
    local callbacks = 0
    local credentials = machine_credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-access-token" }
    end)
    local tokens = {}

    assert.is_true(auth.authenticate(
      successful_commands(tokens),
      fake_runtime.new(),
      credentials
    ))
    assert.is_true(auth.authenticate(
      successful_commands(tokens),
      fake_runtime.new(),
      credentials
    ))

    assert.are.same({ "private-access-token", "private-access-token" }, tokens)
    assert.are.equal(1, callbacks)
  end)

  it("keeps client caches independent", function()
    local callbacks = 0
    local callback = function()
      callbacks = callbacks + 1
      return { access_token = "private-token-" .. callbacks }
    end
    local tokens = {}

    assert.is_true(auth.authenticate(
      successful_commands(tokens),
      fake_runtime.new(),
      machine_credentials(callback)
    ))
    assert.is_true(auth.authenticate(
      successful_commands(tokens),
      fake_runtime.new(),
      machine_credentials(callback)
    ))

    assert.are.same({ "private-token-1", "private-token-2" }, tokens)
    assert.are.equal(2, callbacks)
  end)

  it("does not evict a token from its advisory expiry", function()
    local callbacks = 0
    local credentials = machine_credentials(function()
      callbacks = callbacks + 1
      return {
        access_token = "private-access-token",
        expires_in_seconds = 0,
      }
    end)
    local runtime = fake_runtime.new()
    local tokens = {}

    assert.is_true(auth.authenticate(
      successful_commands(tokens),
      runtime,
      credentials
    ))
    runtime:advance(3600)
    assert.is_true(auth.authenticate(
      successful_commands(tokens),
      runtime,
      credentials
    ))

    assert.are.equal(1, callbacks)
  end)

  it("invalidates only the exact token used by a connection", function()
    local callbacks = 0
    local credentials = machine_credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-access-token" }
    end)
    local runtime = fake_runtime.new()
    local tokens = {}
    local first_connection = successful_commands(tokens)

    assert.is_true(auth.authenticate(first_connection, runtime, credentials))

    local attempts = 0
    local refreshing_connection = {
      command = function(_, _, body)
        local payload = assert(bson.decode(body:get("payload").data))

        attempts = attempts + 1
        tokens[#tokens + 1] = payload:get("jwt")

        if attempts == 1 then
          return nil, server_error(18, "private access token was rejected")
        end

        return success_response()
      end,
    }

    assert.is_true(auth.authenticate(
      refreshing_connection,
      runtime,
      credentials
    ))
    assert.is_true(oidc.invalidate(first_connection, credentials))

    local current_connection = successful_commands(tokens)

    assert.is_true(auth.authenticate(current_connection, runtime, credentials))
    assert.are.equal(2, callbacks)
    assert.is_true(oidc.invalidate(current_connection, credentials))
    assert.is_true(auth.authenticate(
      successful_commands(tokens),
      runtime,
      credentials
    ))
    assert.are.equal(3, callbacks)
    assert.are.same({
      "private-access-token",
      "private-access-token",
      "private-access-token",
      "private-access-token",
      "private-access-token",
    }, tokens)
  end)

  it("retains cached tokens after non-authentication failures", function()
    local callbacks = 0
    local credentials = machine_credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-access-token" }
    end)
    local runtime = fake_runtime.new()
    local tokens = {}

    assert.is_true(auth.authenticate(
      successful_commands(tokens),
      runtime,
      credentials
    ))

    local authenticated, err = auth.authenticate({
      command = function()
        return nil, server_error(91, "private-access-token unavailable")
      end,
    }, runtime, credentials)

    assert.is_nil(authenticated)
    assert.are.equal(91, err.code)
    assert.is_nil(tostring(err):find("private", 1, true))
    assert.is_true(auth.authenticate(
      successful_commands(tokens),
      runtime,
      credentials
    ))
    assert.are.equal(1, callbacks)
  end)

  it("does not retain a newly rejected token", function()
    local callbacks = 0
    local credentials = machine_credentials(function()
      callbacks = callbacks + 1
      return { access_token = "private-token-" .. callbacks }
    end)
    local runtime = fake_runtime.new()
    local authenticated, err = auth.authenticate({
      command = function()
        return nil, server_error(18, "private-token-1 was rejected")
      end,
    }, runtime, credentials)

    assert.is_nil(authenticated)
    assert.are.equal(18, err.code)
    assert.is_nil(tostring(err):find("private", 1, true))

    local tokens = {}

    assert.is_true(auth.authenticate(
      successful_commands(tokens),
      runtime,
      credentials
    ))
    assert.are.same({ "private-token-2" }, tokens)
    assert.are.equal(2, callbacks)
  end)
end)
