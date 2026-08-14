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

  it("runs every AUTH-002 legacy credential case", function()
    assert.are.equal(18, auth_config_runner.run_auth_002())
  end)

  it("runs every AUTH-003 PLAIN credential case", function()
    assert.are.equal(4, auth_config_runner.run_auth_003())
  end)

  it("runs every AUTH-004 X.509 credential case", function()
    assert.are.equal(7, auth_config_runner.run_auth_004())
  end)
end)
