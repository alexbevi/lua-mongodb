local auth_config_runner = require("spec.support.auth_config_runner")
local auth = require("mongodb.auth")
local bson = require("mongodb.bson")
local client = require("mongodb.client")
local command_executor = require("mongodb.command.executor")
local credentials = require("mongodb.config.credentials")
local errors = require("mongodb.error")
local network_transport = require("mongodb.network.transport")
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

  it("renews the socket timeout for each SCRAM exchange", function()
    local runtime = fake_runtime.new({ now = 10 })
    local socket_deadlines = {}
    local original_authenticate = auth.authenticate
    local original_executor_new = command_executor.new
    local original_transport_connect = network_transport.connect
    local underlying = {
      close = function() return true end,
      command = function(_, _, _, command_options)
        socket_deadlines[#socket_deadlines + 1] = command_options.socket_deadline
        return bson.document({ { "ok", 1 } })
      end,
      hello = function()
        return {
          document = bson.document({ { "ok", 1 } }),
          max_bson_size = 16777216,
          max_message_size = 48000000,
          max_wire_version = 25,
          max_write_batch_size = 100000,
          server_type = "standalone",
        }
      end,
    }

    network_transport.connect = function() return {} end
    command_executor.new = function() return underlying end
    auth.authenticate = function(commands, _, _, auth_options)
      assert(commands:command(
        "admin",
        bson.document({ { "saslStart", 1 } }),
        { deadline = auth_options.deadline }
      ))
      runtime:advance(1)
      assert(commands:command(
        "admin",
        bson.document({ { "saslContinue", 1 } }),
        { deadline = auth_options.deadline }
      ))
      return true
    end

    local outcome = table.pack(pcall(function()
      local connected = assert(client.connect(
        "mongodb://alice:secret@localhost/"
          .. "?authMechanism=SCRAM-SHA-256"
          .. "&connectTimeoutMS=250&socketTimeoutMS=250",
        { runtime = runtime }
      ))

      assert(connected:close())
    end))

    auth.authenticate = original_authenticate
    command_executor.new = original_executor_new
    network_transport.connect = original_transport_connect
    assert(outcome[1], outcome[2])
    assert.near(10.25, socket_deadlines[1], 0.000001)
    assert.near(11.25, socket_deadlines[2], 0.000001)
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

  it("normalizes immutable GSSAPI credentials and mechanism properties", function()
    local parsed = assert(uri.parse(
      "mongodb://user%40EXAMPLE.COM:private-password@localhost/database"
        .. "?authMechanism=GSSAPI"
    ))
    local config = assert(options.normalize(parsed.options, {
      auth_mechanism_properties = {
        canonicalize_host_name = true,
        service_host = "db.example.com",
        service_name = "custom",
        service_realm = "SERVICE.EXAMPLE.COM",
      },
    }, parsed))
    local credential = assert(credentials.build(parsed, config))

    assert.are.equal("GSSAPI", credential.mechanism)
    assert.are.equal("user@EXAMPLE.COM", credential.username)
    assert.are.equal("private-password", credential.password)
    assert.are.equal("$external", credential.source)
    assert.are.same({
      CANONICALIZE_HOST_NAME = "forwardAndReverse",
      SERVICE_HOST = "db.example.com",
      SERVICE_NAME = "custom",
      SERVICE_REALM = "SERVICE.EXAMPLE.COM",
    }, credential.mechanism_properties)
    assert.has_error(function()
      credential.mechanism_properties.SERVICE_NAME = "changed"
    end, "authentication credentials are immutable")
  end)

  it("rejects invalid GSSAPI configuration without exposing values", function()
    for _, query in ipairs({
      "authSource=private-source",
      "authMechanismProperties=CANONICALIZE_HOST_NAME:private-mode",
      "authMechanismProperties=PRIVATE_PROPERTY:private-value",
    }) do
      local parsed = assert(uri.parse(
        "mongodb://user%40EXAMPLE.COM:private-password@localhost/"
          .. "?authMechanism=GSSAPI&" .. query
      ))
      local config = assert(options.normalize(parsed.options, nil, parsed))
      local credential, err = credentials.build(parsed, config)

      assert.is_nil(credential)
      assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
      assert.is_nil(tostring(err):find("private", 1, true))
    end
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

  it("runs every AUTH-031 GSSAPI credential case", function()
    assert.are.equal(10, auth_config_runner.run_auth_031())
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
