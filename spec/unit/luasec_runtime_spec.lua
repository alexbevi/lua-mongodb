local fake_runtime = require("mongodb.runtime.fake")
local luasec = require("mongodb.runtime.luasec")

describe("LuaSec TLS runtime adapter", function()
  it("builds a verified client context with SNI and client credentials", function()
    local runtime = fake_runtime.new()
    local captured
    local socket = {}
    local wrapped = {}
    local provider = luasec.new(runtime, {
      default_ca_file = "/system/ca.pem",
      socket_adapter = {
        wrap_tls = function(input, parameters, hostname, check_hostname)
          captured = {
            check_hostname = check_hostname,
            hostname = hostname,
            input = input,
            parameters = parameters,
          }
          return wrapped
        end,
      },
      ssl = {
        newcontext = function(parameters)
          return parameters
        end,
      },
    })

    assert.are.equal(wrapped, assert(provider:wrap(socket, {
      ca_file = "/custom/ca.pem",
      certificate_key_file = "/client.pem",
      certificate_key_file_password = "secret",
      server_name = "db.example.com",
    })))
    assert.are.equal(socket, captured.input)
    assert.are.equal("db.example.com", captured.hostname)
    assert.is_true(captured.check_hostname)
    assert.are.equal("client", captured.parameters.mode)
    assert.are.equal("any", captured.parameters.protocol)
    assert.are.same({ "peer", "fail_if_no_peer_cert" }, captured.parameters.verify)
    assert.are.equal("/custom/ca.pem", captured.parameters.cafile)
    assert.are.equal("/client.pem", captured.parameters.certificate)
    assert.are.equal("/client.pem", captured.parameters.key)
    assert.are.equal("secret", captured.parameters.password)
  end)

  it("maps insecure flags without weakening the default policy", function()
    local runtime = fake_runtime.new()
    local calls = {}
    local provider = luasec.new(runtime, {
      default_ca_file = "/system/ca.pem",
      socket_adapter = {
        wrap_tls = function(_, parameters, _, check_hostname, deadline, token)
          calls[#calls + 1] = {
            check_hostname = check_hostname,
            deadline = deadline,
            parameters = parameters,
            token = token,
          }
          return {}
        end,
      },
      ssl = { newcontext = function(parameters) return parameters end },
    })
    local token = runtime.cancellation:new()

    assert(provider:wrap({}, { server_name = "db.example.com" }, 12, token))
    assert.are.same({ "peer", "fail_if_no_peer_cert" }, calls[1].parameters.verify)
    assert.are.equal("/system/ca.pem", calls[1].parameters.cafile)
    assert.is_true(calls[1].check_hostname)
    assert.are.equal(12, calls[1].deadline)
    assert.are.equal(token, calls[1].token)

    assert(provider:wrap({}, {
      insecure = true,
      server_name = "db.example.com",
    }))
    assert.are.equal("none", calls[2].parameters.verify)
    assert.is_nil(calls[2].parameters.cafile)
    assert.is_false(calls[2].check_hostname)

    assert(provider:wrap({}, {
      allow_invalid_hostnames = true,
      server_name = "db.example.com",
    }))
    assert.are.same({ "peer", "fail_if_no_peer_cert" }, calls[3].parameters.verify)
    assert.is_false(calls[3].check_hostname)

    assert(provider:wrap({}, {
      allow_invalid_certificates = true,
      server_name = "db.example.com",
    }))
    assert.are.equal("none", calls[4].parameters.verify)
    assert.is_false(calls[4].check_hostname)
  end)

  it("returns redacted context configuration failures", function()
    local runtime = fake_runtime.new()
    local provider = luasec.new(runtime, {
      socket_adapter = { wrap_tls = function() error("must not wrap") end },
      ssl = {
        newcontext = function()
          return nil, "failed to decrypt secret-password at /private/client.pem"
        end,
      },
    })
    local value, err = provider:wrap({}, {
      certificate_key_file = "/private/client.pem",
      certificate_key_file_password = "secret-password",
      insecure = true,
      server_name = "db.example.com",
    })

    assert.is_nil(value)
    assert.are.equal("configuration", err.category)
    assert.are.equal("TLS context configuration failed", err.message)
    assert.is_nil(tostring(err):find("secret-password", 1, true))
    assert.is_nil(tostring(err):find("/private/client.pem", 1, true))
  end)
end)
