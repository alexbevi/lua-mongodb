local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local x509 = require("mongodb.auth.x509")

describe("MONGODB-X509 authentication", function()
  it("authenticates with an explicit or certificate-derived subject", function()
    for _, username in ipairs({ "CN=client", false }) do
      local observed
      local commands = {
        command = function(_, source, body, options)
          observed = { body = body, options = options, source = source }
          return bson.document({ { "ok", 1 } })
        end,
      }

      assert.is_true(x509.authenticate(commands, {
        mechanism = "MONGODB-X509",
        source = "$external",
        username = username or nil,
      }, {}))
      assert.are.equal("$external", observed.source)
      assert.are.equal("authenticate", observed.body:keys()[1])
      assert.are.equal("MONGODB-X509", observed.body:get("mechanism"))

      if username then
        assert.are.equal(username, observed.body:get("user"))
      else
        assert.is_nil(observed.body:get("user"))
      end
    end
  end)

  it("sanitizes command failures and rejects malformed responses", function()
    local commands = {
      command = function()
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          code = 18,
          message = "server exposed a certificate subject",
        })
      end,
    }
    local authenticated, err = x509.authenticate(commands, {
      mechanism = "MONGODB-X509",
      source = "$external",
      username = "CN=private-client",
    })

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal(18, err.code)
    assert.is_nil(tostring(err):find("certificate subject", 1, true))
    assert.is_nil(tostring(err):find("private-client", 1, true))

    commands.command = function()
      return true
    end
    authenticated, err = x509.authenticate(commands, {
      mechanism = "MONGODB-X509",
      source = "$external",
    })

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
  end)
end)
