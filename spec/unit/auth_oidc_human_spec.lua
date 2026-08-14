local auth = require("mongodb.auth")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local function human_credentials(callback, username)
  return {
    mechanism = "MONGODB-OIDC",
    mechanism_properties = {
      ALLOWED_HOSTS = { "login.example.com" },
      OIDC_HUMAN_CALLBACK = callback,
    },
    source = "$external",
    username = username,
  }
end

local function idp_response(payload, conversation_id)
  return bson.document({
    { "conversationId", conversation_id or 7 },
    { "payload", bson.binary(payload) },
    { "done", false },
    { "ok", 1 },
  })
end

local function valid_idp_payload()
  return assert(bson.encode(bson.document({
    { "issuer", "https://issuer.example.com" },
    { "clientId", "client-id" },
    { "requestScopes", bson.array({ "openid", "profile" }) },
  })))
end

local function success_response(conversation_id)
  return bson.document({
    { "conversationId", conversation_id or 7 },
    { "payload", bson.binary("") },
    { "done", true },
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

describe("MONGODB-OIDC human authentication", function()
  it("passes IdP context through a two-step SASL exchange", function()
    local runtime = fake_runtime.new({ now = 10 })
    local calls = 0
    local idp_payload = valid_idp_payload()
    local commands = {
      command = function(_, source, body)
        calls = calls + 1
        assert.are.equal("$external", source)

        local payload = assert(bson.decode(body:get("payload").data))

        if calls == 1 then
          assert.are.equal("saslStart", body:keys()[1])
          assert.are.equal("MONGODB-OIDC", body:get("mechanism"))
          assert.are.equal("human-user", payload:get("n"))
          return bson.document({
            { "conversationId", 7 },
            { "payload", bson.binary(idp_payload) },
            { "done", false },
            { "ok", 1 },
          })
        end

        assert.are.equal("saslContinue", body:keys()[1])
        assert.are.equal(7, body:get("conversationId"))
        assert.are.equal("private-access-token", payload:get("jwt"))
        return bson.document({
          { "conversationId", 7 },
          { "payload", bson.binary("") },
          { "done", true },
          { "ok", 1 },
        })
      end,
    }

    assert.is_true(auth.authenticate(
      commands,
      runtime,
      human_credentials(function(context)
        assert.are.equal(310, context.deadline)
        assert.are.equal(300, context.timeout_seconds)
        assert.are.equal("human-user", context.username)
        assert.are.equal(1, context.version)
        assert.is_nil(context.refresh_token)
        assert.are.equal(
          "https://issuer.example.com",
          context.idp_info.issuer
        )
        assert.are.equal("client-id", context.idp_info.client_id)
        assert.are.same(
          { "openid", "profile" },
          context.idp_info.request_scopes
        )
        assert.has_error(function()
          context.version = 2
        end, "OIDC callback contexts are immutable")
        assert.has_error(function()
          context.idp_info.issuer = "https://private.example.com"
        end, "OIDC callback contexts are immutable")
        assert.has_error(function()
          context.idp_info.request_scopes[1] = "private-scope"
        end, "OIDC callback contexts are immutable")
        return {
          access_token = "private-access-token",
          refresh_token = "private-refresh-token",
        }
      end, "human-user"),
      { deadline = 11, server_host = "login.example.com" }
    ))
    assert.are.equal(2, calls)
  end)

  it("omits an absent principal from saslStart", function()
    local calls = 0
    local commands = {
      command = function(_, _, body)
        calls = calls + 1
        local payload = assert(bson.decode(body:get("payload").data))

        if calls == 1 then
          assert.is_nil(payload:get("n"))
          assert.are.same({}, payload:keys())
          return idp_response(assert(bson.encode(bson.document({
            { "issuer", "https://issuer.example.com" },
          }))))
        end

        assert.are.equal("private-access-token", payload:get("jwt"))
        return success_response()
      end,
    }

    assert.is_true(auth.authenticate(
      commands,
      fake_runtime.new(),
      human_credentials(function(context)
        assert.are.equal("", context.username)
        return { access_token = "private-access-token" }
      end),
      { server_host = "login.example.com" }
    ))
    assert.are.equal(2, calls)
  end)

  it("rejects malformed IdP responses before invoking the callback", function()
    local invalid_responses = {
      bson.document({
        { "conversationId", 7 },
        { "payload", bson.binary(valid_idp_payload()) },
        { "done", true },
      }),
      bson.document({
        { "conversationId", "private-conversation" },
        { "payload", bson.binary(valid_idp_payload()) },
        { "done", false },
      }),
      bson.document({
        { "conversationId", 7 },
        { "payload", bson.binary("private-invalid-bson") },
        { "done", false },
      }),
      idp_response(assert(bson.encode(bson.document({
        { "issuer", false },
      })))),
      idp_response(assert(bson.encode(bson.document({
        { "issuer", "https://private.example.com" },
        { "requestScopes", bson.array({ "openid", false }) },
      })))),
      idp_response(assert(bson.encode(bson.document({
        { "issuer", "https://private.example.com" },
        { "unknown", "private-value" },
      })))),
    }

    for _, response in ipairs(invalid_responses) do
      local callbacks = 0
      local authenticated, err = auth.authenticate({
        command = function()
          return response
        end,
      }, fake_runtime.new(), human_credentials(function()
        callbacks = callbacks + 1
      end), { server_host = "login.example.com" })

      assert.is_nil(authenticated)
      assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
      assert.are.equal(
        "MONGODB-OIDC server returned an invalid IdP response",
        err.message
      )
      assert.are.equal(0, callbacks)
      assert.is_nil(tostring(err):find("private", 1, true))
    end
  end)

  it("rejects invalid callback results without sending saslContinue", function()
    local invalid_results = {
      false,
      {},
      { access_token = false },
      { access_token = "" },
      { access_token = "private-token", expires_in_seconds = -1 },
      { access_token = "private-token", refresh_token = false },
      { access_token = "private-token", refresh_token = "" },
    }

    for _, result in ipairs(invalid_results) do
      local commands = 0
      local authenticated, err = auth.authenticate({
        command = function()
          commands = commands + 1
          return idp_response(valid_idp_payload())
        end,
      }, fake_runtime.new(), human_credentials(function()
        return result
      end), { server_host = "login.example.com" })

      assert.is_nil(authenticated)
      assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
      assert.are.equal(1, commands)
      assert.is_nil(tostring(err):find("private", 1, true))
    end

    local authenticated, err = auth.authenticate({
      command = function()
        return idp_response(valid_idp_payload())
      end,
    }, fake_runtime.new(), human_credentials(function()
      error("private callback failure")
    end), { server_host = "login.example.com" })

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.is_nil(tostring(err):find("private", 1, true))
  end)

  it("enforces the five-minute callback deadline independently of CSOT", function()
    local runtime = fake_runtime.new({ now = 10 })
    local commands = 0
    local authenticated, err = auth.authenticate({
      command = function()
        commands = commands + 1
        return idp_response(valid_idp_payload())
      end,
    }, runtime, human_credentials(function(context)
      assert.are.equal(310, context.deadline)
      assert.are.equal(300, context.timeout_seconds)
      runtime:advance(301)
      return { access_token = "private-access-token" }
    end), { deadline = 11, server_host = "login.example.com" })

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.is_true(err.timeout)
    assert.are.equal(1, commands)
    assert.is_nil(tostring(err):find("private", 1, true))
  end)

  it("sanitizes SASL command failures and invalid continuations", function()
    local authenticated, err = auth.authenticate({
      command = function()
        return nil, server_error(18, "private start failure")
      end,
    }, fake_runtime.new(), human_credentials(function()
      error("callback must not run")
    end), { server_host = "login.example.com" })

    assert.is_nil(authenticated)
    assert.are.equal(18, err.code)
    assert.is_nil(tostring(err):find("private", 1, true))

    local calls = 0
    authenticated, err = auth.authenticate({
      command = function()
        calls = calls + 1

        if calls == 1 then
          return idp_response(valid_idp_payload())
        end

        return nil, server_error(18, "private-access-token was rejected")
      end,
    }, fake_runtime.new(), human_credentials(function()
      return { access_token = "private-access-token" }
    end), { server_host = "login.example.com" })

    assert.is_nil(authenticated)
    assert.are.equal(18, err.code)
    assert.is_nil(tostring(err):find("private", 1, true))

    calls = 0
    authenticated, err = auth.authenticate({
      command = function()
        calls = calls + 1

        if calls == 1 then
          return idp_response(valid_idp_payload())
        end

        return success_response(8)
      end,
    }, fake_runtime.new(), human_credentials(function()
      return { access_token = "private-access-token" }
    end), { server_host = "login.example.com" })

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.is_nil(tostring(err):find("private", 1, true))
  end)
end)
