local auth = require("mongodb.auth")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local function human_credentials(allowed_hosts, callback)
  return {
    mechanism = "MONGODB-OIDC",
    mechanism_properties = {
      ALLOWED_HOSTS = allowed_hosts,
      OIDC_HUMAN_CALLBACK = callback or function() end,
    },
    source = "$external",
  }
end

local function authenticate(credentials, host)
  local commands = 0
  local authenticated, err = auth.authenticate({
    command = function()
      commands = commands + 1
    end,
  }, fake_runtime.new(), credentials, { server_host = host })

  return authenticated, err, commands
end

describe("MONGODB-OIDC human allowed hosts", function()
  it("rejects an unlisted host before callback or SASL", function()
    local callbacks = 0
    local credentials = human_credentials({ "login.example.com" }, function()
      callbacks = callbacks + 1
    end)
    local authenticated, err, commands = authenticate(
      credentials,
      "private.example.com"
    )

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal("MONGODB-OIDC human callback host is not allowed", err.message)
    assert.are.equal(0, callbacks)
    assert.are.equal(0, commands)
    assert.is_nil(tostring(err):find("private.example.com", 1, true))
  end)

  it("accepts exact hosts and wildcard subdomains", function()
    local credentials = human_credentials({
      "login.example.com",
      "*.example.net",
      "127.0.0.1",
      "::1",
    })

    for _, host in ipairs({
      "login.example.com",
      "api.example.net",
      "deep.api.example.net",
      "127.0.0.1",
      "::1",
    }) do
      local authenticated, err, commands = authenticate(credentials, host)

      assert.is_nil(authenticated)
      assert.are.equal(
        "MONGODB-OIDC human authentication is not implemented",
        err.message
      )
      assert.are.equal(0, commands)
    end
  end)

  it("rejects roots, partial suffixes, and missing hosts", function()
    local credentials = human_credentials({ "*.example.net" })

    for _, host in ipairs({
      "example.net",
      "notexample.net",
      "example.net.attacker.test",
      false,
    }) do
      local authenticated, err, commands = authenticate(credentials, host)

      assert.is_nil(authenticated)
      assert.are.equal(
        "MONGODB-OIDC human callback host is not allowed",
        err.message
      )
      assert.are.equal(0, commands)
    end
  end)
end)
