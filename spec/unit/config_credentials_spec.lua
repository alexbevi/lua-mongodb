local auth_config_runner = require("spec.support.auth_config_runner")
local client = require("mongodb.client")
local credentials = require("mongodb.config.credentials")
local errors = require("mongodb.error")
local options = require("mongodb.config.options")
local fake_runtime = require("mongodb.runtime.fake")
local uri = require("mongodb.config.uri")

describe("authentication credential normalization", function()
  it("builds immutable default SCRAM credentials before connection", function()
    local parsed = assert(uri.parse("mongodb://alice:secret@localhost/accounts"))
    local config = assert(options.normalize(parsed.options, nil, parsed))
    local credential = assert(credentials.build(parsed, config))

    assert.is_nil(credential.mechanism)
    assert.are.equal("alice", credential.username)
    assert.are.equal("secret", credential.password)
    assert.are.equal("accounts", credential.source)
    assert.has_error(function()
      credential.source = "admin"
    end, "authentication credentials are immutable")
  end)

  it("does not create credentials from a database or authSource alone", function()
    for _, value in ipairs({
      "mongodb://localhost/accounts",
      "mongodb://localhost/?authSource=accounts",
    }) do
      local parsed = assert(uri.parse(value))
      local config = assert(options.normalize(parsed.options, nil, parsed))

      assert.is_nil(credentials.build(parsed, config))
    end
  end)

  it("rejects incomplete SCRAM credentials before networking", function()
    local runtime = fake_runtime.new()
    local connected, err = client.connect(
      "mongodb://localhost/?authMechanism=SCRAM-SHA-256",
      { runtime = runtime }
    )

    assert.is_nil(connected)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("username", err.details.option)
    assert.are.same({}, runtime.calls.connect)
  end)

  it("rejects SCRAM mechanism properties without exposing their values", function()
    local parsed = assert(uri.parse(
      "mongodb://alice:secret@localhost/"
        .. "?authMechanismProperties=SERVICE_NAME:private-value"
    ))
    local config = assert(options.normalize(parsed.options, nil, parsed))
    local credential, err = credentials.build(parsed, config)

    assert.is_nil(credential)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("auth_mechanism_properties", err.details.option)
    assert.is_nil(tostring(err):find("private-value", 1, true))
  end)

  it("creates only provider-backed MONGODB-AWS credentials", function()
    local parsed = assert(uri.parse(
      "mongodb://localhost/?authMechanism=MONGODB-AWS"
    ))
    local config = assert(options.normalize(parsed.options, nil, parsed))
    local credential = assert(credentials.build(parsed, config))

    assert.are.equal("MONGODB-AWS", credential.mechanism)
    assert.are.equal("$external", credential.source)
    assert.is_nil(credential.username)
    assert.is_nil(credential.password)

    parsed = assert(uri.parse(
      "mongodb://access-key:private-secret@localhost/"
        .. "?authMechanism=MONGODB-AWS"
    ))
    config = assert(options.normalize(parsed.options, nil, parsed))
    local credential_err
    credential, credential_err = credentials.build(parsed, config)

    assert.is_nil(credential)
    assert.is_true(errors.is(credential_err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("username", credential_err.details.option)
    assert.is_nil(tostring(credential_err):find("private-secret", 1, true))
  end)

  it("normalizes a built-in MONGODB-OIDC environment credential", function()
    local parsed = assert(uri.parse(
      "mongodb://localhost/?authMechanism=MONGODB-OIDC"
        .. "&authMechanismProperties=ENVIRONMENT:test"
    ))
    local config = assert(options.normalize(parsed.options, nil, parsed))
    local credential = assert(credentials.build(parsed, config))

    assert.are.equal("MONGODB-OIDC", credential.mechanism)
    assert.are.equal("$external", credential.source)
    assert.is_nil(credential.username)
    assert.is_nil(credential.password)
    assert.are.same({ ENVIRONMENT = "test" }, credential.mechanism_properties)
    assert.has_error(function()
      credential.mechanism_properties.ENVIRONMENT = "private"
    end, "authentication credentials are immutable")
  end)

  it("rejects invalid OIDC URI environment configuration without values", function()
    local cases = {
      "authSource=admin&authMechanismProperties=ENVIRONMENT:test",
      "authMechanismProperties=ENVIRONMENT:gcp",
      "authMechanismProperties=ENVIRONMENT:k8s,TOKEN_RESOURCE:private-resource",
      "authMechanismProperties=ENVIRONMENT:test,OIDC_CALLBACK:private-callback",
      "authMechanismProperties=ENVIRONMENT:test,ALLOWED_HOSTS:private-host",
    }

    for _, query in ipairs(cases) do
      local parsed = assert(uri.parse(
        "mongodb://localhost/?authMechanism=MONGODB-OIDC&" .. query
      ))
      local config = assert(options.normalize(parsed.options, nil, parsed))
      local credential, err = credentials.build(parsed, config)

      assert.is_nil(credential)
      assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
      assert.is_nil(tostring(err):find("private", 1, true))
    end
  end)

  it("runs every AUTH-002 legacy credential case", function()
    assert.are.equal(18, auth_config_runner.run_auth_002())
  end)

  it("runs every AUTH-003 PLAIN credential case", function()
    assert.are.equal(4, auth_config_runner.run_auth_003())
  end)

  it("runs every AUTH-004 X.509 credential case", function()
    assert.are.equal(7, auth_config_runner.run_auth_004())
  end)

  it("runs and classifies every AUTH-020 AWS credential case", function()
    assert.are.same({
      executed = 8,
      passed = 6,
      superseded = 2,
    }, auth_config_runner.run_auth_020())
  end)

  it("runs every AUTH-010 OIDC environment credential case", function()
    assert.are.equal(20, auth_config_runner.run_auth_010())
  end)
end)
