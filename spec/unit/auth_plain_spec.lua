local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local plain = require("mongodb.auth.plain")

describe("SASL PLAIN authentication", function()
  it("sends the RFC 4616 initial response to the credential source", function()
    local observed
    local commands = {
      command = function(_, source, body, options)
        observed = { body = body, options = options, source = source }
        return bson.document({
          { "conversationId", 1 },
          { "payload", bson.binary("") },
          { "done", true },
          { "ok", 1 },
        })
      end,
    }

    assert.is_true(plain.authenticate(commands, {
      mechanism = "PLAIN",
      password = "pencil",
      source = "$external",
      username = "user",
    }, {}))
    assert.are.equal("$external", observed.source)
    assert.are.equal("saslStart", observed.body:keys()[1])
    assert.are.equal("PLAIN", observed.body:get("mechanism"))
    assert.are.equal("\0user\0pencil", observed.body:get("payload").data)
    assert.are.equal(1, observed.body:get("autoAuthorize"))
  end)

  it("sanitizes server failures and rejects incomplete responses", function()
    local commands = {
      command = function()
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          code = 18,
          message = "server exposed a credential payload",
        })
      end,
    }
    local authenticated, err = plain.authenticate(commands, {
      mechanism = "PLAIN",
      password = "private-password",
      source = "$external",
      username = "user",
    })

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal(18, err.code)
    assert.is_nil(tostring(err):find("credential payload", 1, true))
    assert.is_nil(tostring(err):find("private-password", 1, true))

    commands.command = function()
      return bson.document({
        { "conversationId", 1 },
        { "payload", bson.binary("") },
        { "done", false },
        { "ok", 1 },
      })
    end
    authenticated, err = plain.authenticate(commands, {
      mechanism = "PLAIN",
      password = "private-password",
      source = "$external",
      username = "user",
    })

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
  end)
end)
