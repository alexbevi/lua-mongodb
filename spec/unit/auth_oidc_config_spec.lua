local credentials = require("mongodb.config.credentials")
local errors = require("mongodb.error")
local options = require("mongodb.config.options")
local uri = require("mongodb.config.uri")

local DEFAULT_ALLOWED_HOSTS = {
  "*.mongodb.net",
  "*.mongodb-qa.net",
  "*.mongodb-dev.net",
  "*.mongodbgov.net",
  "localhost",
  "127.0.0.1",
  "::1",
  "*.mongo.com",
}

local function build(properties)
  local parsed = assert(uri.parse(
    "mongodb://localhost/?authMechanism=MONGODB-OIDC"
  ))
  local config = assert(options.normalize(parsed.options, {
    auth_mechanism_properties = properties,
  }, parsed))

  return credentials.build(parsed, config)
end

describe("MONGODB-OIDC callback configuration", function()
  it("normalizes a programmatic machine callback", function()
    local callback = function() end
    local credential = assert(build({ OIDC_CALLBACK = callback }))

    assert.are.equal(callback, credential.mechanism_properties.OIDC_CALLBACK)
    assert.is_nil(credential.mechanism_properties.ALLOWED_HOSTS)
    assert.has_error(function()
      credential.mechanism_properties.OIDC_CALLBACK = function() end
    end, "authentication credentials are immutable")
  end)

  it("gives human callbacks the immutable normative allowed hosts", function()
    local callback = function() end
    local credential = assert(build({ OIDC_HUMAN_CALLBACK = callback }))
    local properties = credential.mechanism_properties

    assert.are.equal(callback, properties.OIDC_HUMAN_CALLBACK)
    assert.are.same(DEFAULT_ALLOWED_HOSTS, properties.ALLOWED_HOSTS)
    assert.has_error(function()
      properties.ALLOWED_HOSTS[1] = "private-host"
    end, "authentication credentials are immutable")
  end)

  it("copies a human callback custom allowed-host list", function()
    local allowed_hosts = { "login.example.com", "*.example.net" }
    local parsed = assert(uri.parse(
      "mongodb://localhost/?authMechanism=MONGODB-OIDC"
    ))
    local config = assert(options.normalize(parsed.options, {
      auth_mechanism_properties = {
        ALLOWED_HOSTS = allowed_hosts,
        OIDC_HUMAN_CALLBACK = function() end,
      },
    }, parsed))

    allowed_hosts[1] = "private-host"
    local credential = assert(credentials.build(parsed, config))

    assert.are.same({ "login.example.com", "*.example.net" },
      credential.mechanism_properties.ALLOWED_HOSTS)
  end)

  it("requires exactly one environment or callback identity", function()
    local callback = function() end
    local cases = {
      {},
      { ENVIRONMENT = "test", OIDC_CALLBACK = callback },
      { OIDC_CALLBACK = callback, OIDC_HUMAN_CALLBACK = callback },
    }

    for _, properties in ipairs(cases) do
      local credential, err = build(properties)

      assert.is_nil(credential)
      assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
      assert.are.equal("auth_mechanism_properties", err.details.option)
    end
  end)

  it("accepts allowed hosts only for human callbacks", function()
    local credential, err = build({
      ALLOWED_HOSTS = { "private-host" },
      OIDC_CALLBACK = function() end,
    })

    assert.is_nil(credential)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("auth_mechanism_properties", err.details.option)
    assert.is_nil(tostring(err):find("private-host", 1, true))
  end)

  it("rejects token resources with callbacks without exposing them", function()
    local credential, err = build({
      OIDC_CALLBACK = function() end,
      TOKEN_RESOURCE = "private-token-resource",
    })

    assert.is_nil(credential)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("auth_mechanism_properties", err.details.option)
    assert.is_nil(tostring(err):find("private-token-resource", 1, true))
  end)

  it("rejects callback and allowed-host material from URI diagnostics", function()
    for _, value in ipairs({
      "OIDC_CALLBACK:private-callback",
      "OIDC_HUMAN_CALLBACK:private-human-callback",
      "ALLOWED_HOSTS:private-host",
    }) do
      local parsed = assert(uri.parse(
        "mongodb://localhost/?authMechanism=MONGODB-OIDC&"
          .. "authMechanismProperties=" .. value
      ))
      local config = assert(options.normalize(parsed.options, nil, parsed))
      local credential, err = credentials.build(parsed, config)

      assert.is_nil(credential)
      assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
      assert.is_nil(tostring(err):find("private", 1, true))
    end
  end)

  it("rejects malformed custom allowed-host lists", function()
    local cases = {
      { "example.com", false },
      { [2] = "example.com" },
      { named = "example.com" },
    }

    for _, allowed_hosts in ipairs(cases) do
      local credential, err = build({
        ALLOWED_HOSTS = allowed_hosts,
        OIDC_HUMAN_CALLBACK = function() end,
      })

      assert.is_nil(credential)
      assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
      assert.are.equal("auth_mechanism_properties", err.details.option)
    end
  end)
end)
