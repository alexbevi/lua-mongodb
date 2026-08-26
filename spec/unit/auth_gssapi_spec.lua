local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local gssapi = require("mongodb.auth.gssapi")

local function response(payload, done, identifier)
  return bson.document({
    { "conversationId", identifier or 41 },
    { "payload", bson.binary(payload) },
    { "done", done },
    { "ok", 1 },
  })
end

describe("GSSAPI authentication", function()
  it("completes the SASL and security-layer exchanges", function()
    local runtime = fake_runtime.new()
    local cancellation = runtime.cancellation:new()
    local closed = 0
    local provider_steps = 0

    runtime.gssapi = {
      create_context = function(
        _,
        provider_options,
        provider_deadline,
        provider_token
      )
        assert.are.equal(
          "other@db.example.com@REALM",
          provider_options.service_principal
        )
        assert.are.equal("user@REALM", provider_options.username)
        assert.are.equal("private-password", provider_options.password)
        assert.are.equal(25, provider_deadline)
        assert.are.equal(cancellation, provider_token)

        return {
          close = function()
            closed = closed + 1
            return true
          end,
          security_layer = function(
            _,
            challenge,
            username,
            layer_deadline,
            layer_token
          )
            assert.are.equal("server-layer", challenge)
            assert.are.equal("user@REALM", username)
            assert.are.equal(25, layer_deadline)
            assert.are.equal(cancellation, layer_token)
            return "client-layer"
          end,
          step = function(_, challenge, step_deadline, step_token)
            assert.are.equal(25, step_deadline)
            assert.are.equal(cancellation, step_token)
            provider_steps = provider_steps + 1

            if provider_steps == 1 then
              assert.are.equal("", challenge)
              return { complete = false, token = "client-one" }
            end

            assert.are.equal("server-one", challenge)
            return { complete = true, token = "client-two" }
          end,
        }
      end,
    }

    local command_steps = 0
    local commands = {
      command = function(_, source, body, command_options)
        command_steps = command_steps + 1
        assert.are.equal("$external", source)
        assert.are.equal(25, command_options.deadline)
        assert.are.equal(cancellation, command_options.cancellation)

        if command_steps == 1 then
          assert.are.equal("saslStart", body:keys()[1])
          assert.are.equal("GSSAPI", body:get("mechanism"))
          assert.are.equal("client-one", body:get("payload").data)
          assert.are.equal(1, body:get("autoAuthorize"))
          return response("server-one", false)
        elseif command_steps == 2 then
          assert.are.equal("saslContinue", body:keys()[1])
          assert.are.equal(41, body:get("conversationId"))
          assert.are.equal("client-two", body:get("payload").data)
          return response("server-layer", false)
        end

        assert.are.equal("saslContinue", body:keys()[1])
        assert.are.equal(41, body:get("conversationId"))
        assert.are.equal("client-layer", body:get("payload").data)
        return response("", true)
      end,
    }

    assert.is_true(gssapi.authenticate(commands, runtime, {
      mechanism = "GSSAPI",
      mechanism_properties = {
        CANONICALIZE_HOST_NAME = "none",
        SERVICE_NAME = "other",
        SERVICE_REALM = "REALM",
      },
      password = "private-password",
      source = "$external",
      username = "user@REALM",
    }, {
      cancellation = cancellation,
      deadline = 25,
      server_host = "db.example.com",
    }))
    assert.are.equal(3, command_steps)
    assert.are.equal(2, provider_steps)
    assert.are.equal(1, closed)
  end)

  it("bounds provider rounds and closes the context", function()
    local runtime = fake_runtime.new()
    local closed = 0

    runtime.gssapi = {
      create_context = function()
        return {
          close = function()
            closed = closed + 1
            return true
          end,
          security_layer = function()
            error("security-layer negotiation must not start", 0)
          end,
          step = function()
            return { complete = false, token = "client-token" }
          end,
        }
      end,
    }

    local commands = 0
    local authenticated, err = gssapi.authenticate({
      command = function()
        commands = commands + 1
        return response("server-token", false)
      end,
    }, runtime, {
      mechanism = "GSSAPI",
      mechanism_properties = {
        CANONICALIZE_HOST_NAME = "none",
        SERVICE_NAME = "mongodb",
      },
      source = "$external",
      username = "user@REALM",
    }, {
      server_host = "db.example.com",
    })

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.is_not_nil(tostring(err):find("round limit", 1, true))
    assert.are.equal(11, commands)
    assert.are.equal(1, closed)
  end)

  it("rejects a changed conversation id and closes the context", function()
    local runtime = fake_runtime.new()
    local closed = 0
    local provider_steps = 0

    runtime.gssapi = {
      create_context = function()
        return {
          close = function()
            closed = closed + 1
            return true
          end,
          security_layer = function()
            error("security-layer negotiation must not start", 0)
          end,
          step = function()
            provider_steps = provider_steps + 1
            return {
              complete = provider_steps == 2,
              token = "client-token",
            }
          end,
        }
      end,
    }

    local commands = 0
    local authenticated, err = gssapi.authenticate({
      command = function()
        commands = commands + 1

        if commands == 1 then
          return response("server-token", false)
        end

        return response("server-token", false, 42)
      end,
    }, runtime, {
      mechanism = "GSSAPI",
      mechanism_properties = {
        CANONICALIZE_HOST_NAME = "none",
        SERVICE_NAME = "mongodb",
      },
      source = "$external",
      username = "user@REALM",
    }, {
      server_host = "db.example.com",
    })

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.is_not_nil(tostring(err):find("conversation id", 1, true))
    assert.are.equal(1, closed)
  end)

  it("preserves control classification without exposing provider data", function()
    local runtime = fake_runtime.new()
    local closed = 0

    runtime.gssapi = {
      create_context = function()
        return {
          close = function()
            closed = closed + 1
            return true
          end,
          security_layer = function()
            error("security-layer negotiation must not start", 0)
          end,
          step = function()
            return nil, errors.new({
              category = errors.CATEGORY.CANCELLED,
              message = "private principal and token",
            })
          end,
        }
      end,
    }

    local authenticated, err = gssapi.authenticate({
      command = function()
        error("commands must not start", 0)
      end,
    }, runtime, {
      mechanism = "GSSAPI",
      mechanism_properties = {
        CANONICALIZE_HOST_NAME = "none",
        SERVICE_NAME = "mongodb",
      },
      password = "private-password",
      source = "$external",
      username = "private-user@REALM",
    }, {
      server_host = "private.example.com",
    })

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal(errors.CATEGORY.CANCELLED, err.details.source_category)
    assert.is_nil(tostring(err):find("private", 1, true))
    assert.are.equal(1, closed)
  end)

  it("redacts command failures and preserves server metadata", function()
    local runtime = fake_runtime.new()
    local closed = 0

    runtime.gssapi = {
      create_context = function()
        return {
          close = function()
            closed = closed + 1
            return true
          end,
          security_layer = function()
            return "client-layer"
          end,
          step = function()
            return { complete = false, token = "client-token" }
          end,
        }
      end,
    }

    local authenticated, err = gssapi.authenticate({
      command = function()
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          code = 18,
          message = "private principal and provider token",
        })
      end,
    }, runtime, {
      mechanism = "GSSAPI",
      mechanism_properties = {
        CANONICALIZE_HOST_NAME = "none",
        SERVICE_NAME = "mongodb",
      },
      password = "private-password",
      source = "$external",
      username = "private-user@REALM",
    }, {
      server_host = "private.example.com",
    })

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal(18, err.code)
    assert.is_nil(tostring(err):find("private", 1, true))
    assert.are.equal(1, closed)
  end)

  it("rejects malformed provider results and closes the context", function()
    local runtime = fake_runtime.new()
    local closed = 0

    runtime.gssapi = {
      create_context = function()
        return {
          close = function()
            closed = closed + 1
            return true
          end,
          security_layer = function()
            return "client-layer"
          end,
          step = function()
            return "not a token result"
          end,
        }
      end,
    }

    local authenticated, err = gssapi.authenticate({
      command = function()
        error("commands must not start", 0)
      end,
    }, runtime, {
      mechanism = "GSSAPI",
      mechanism_properties = {
        CANONICALIZE_HOST_NAME = "none",
        SERVICE_NAME = "mongodb",
      },
      source = "$external",
      username = "user@REALM",
    }, {
      server_host = "db.example.com",
    })

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.is_not_nil(tostring(err):find("invalid token step", 1, true))
    assert.are.equal(1, closed)
  end)

  it("closes the context when a command raises", function()
    local runtime = fake_runtime.new()
    local closed = 0

    runtime.gssapi = {
      create_context = function()
        return {
          close = function()
            closed = closed + 1
            return true
          end,
          security_layer = function()
            return "client-layer"
          end,
          step = function()
            return { complete = false, token = "client-token" }
          end,
        }
      end,
    }

    assert.has_error(function()
      gssapi.authenticate({
        command = function()
          error("programmer failure", 0)
        end,
      }, runtime, {
        mechanism = "GSSAPI",
        mechanism_properties = {
          CANONICALIZE_HOST_NAME = "none",
          SERVICE_NAME = "mongodb",
        },
        source = "$external",
        username = "user@REALM",
      }, {
        server_host = "db.example.com",
      })
    end, "programmer failure")
    assert.are.equal(1, closed)
  end)
end)
