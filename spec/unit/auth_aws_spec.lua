local auth = require("mongodb.auth")
local aws = require("mongodb.auth.aws")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local openssl_runtime = require("mongodb.runtime.openssl")

local function runtime_with_nonce(nonce, environment)
  local runtime = fake_runtime.new({
    environment = environment,
    wall_time = 1440938160,
  })

  runtime.crypto = openssl_runtime.new().crypto
  runtime:queue_entropy(nonce)
  return runtime
end

local function server_first(client_nonce, host, server_nonce)
  return bson.document({
    { "conversationId", 7 },
    { "done", false },
    { "payload", bson.binary(assert(bson.encode(bson.document({
      { "s", bson.binary(server_nonce or client_nonce .. string.rep("1", 32)) },
      { "h", host or "sts.amazonaws.com" },
    })))) },
    { "ok", 1 },
  })
end

local function resolved_credentials(session_token)
  return {
    mechanism = "MONGODB-AWS",
    password = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    session_token = session_token,
    source = "$external",
    username = "AKIDEXAMPLE",
  }
end

describe("MONGODB-AWS authentication", function()
  it("completes a deterministic static-credential SASL conversation", function()
    local client_nonce = string.rep("0", 32)
    local server_nonce = client_nonce .. string.rep("1", 32)
    local expected_authorization = "AWS4-HMAC-SHA256 "
      .. "Credential=AKIDEXAMPLE/20150830/us-east-1/sts/aws4_request, "
      .. "SignedHeaders=content-length;content-type;host;x-amz-date;"
      .. "x-mongodb-gs2-cb-flag;x-mongodb-server-nonce, "
      .. "Signature=ac77b69be63c05dafd9e52a49c23157f1a2d8a79c59abca50df6099753b6864c"
    local runtime = runtime_with_nonce(client_nonce)

    local step = 0
    local commands = {
      command = function(_, source, body)
        step = step + 1
        assert.are.equal("$external", source)
        assert.is_nil(body:get("payload").data:find("EXAMPLEKEY", 1, true))

        local payload = assert(bson.decode(body:get("payload").data))

        if step == 1 then
          assert.are.equal("saslStart", body:keys()[1])
          assert.are.equal("MONGODB-AWS", body:get("mechanism"))
          assert.are.equal(client_nonce, payload:get("r").data)
          assert.are.equal(110, payload:get("p"):to_number())
          return server_first(client_nonce, "sts.amazonaws.com", server_nonce)
        end

        assert.are.equal("saslContinue", body:keys()[1])
        assert.are.equal(7, body:get("conversationId"))
        assert.are.equal(expected_authorization, payload:get("a"))
        assert.are.equal("20150830T123600Z", payload:get("d"))
        assert.is_nil(payload:get("t"))
        return bson.document({
          { "conversationId", 7 },
          { "done", true },
          { "payload", bson.binary("") },
          { "ok", 1 },
        })
      end,
    }

    assert.is_true(auth.authenticate(
      commands,
      runtime,
      resolved_credentials(),
      { mechanism = "MONGODB-AWS" }
    ))
    assert.are.equal(2, step)
  end)

  it("signs temporary credentials and includes their session token", function()
    local client_nonce = string.rep("0", 32)
    local expected_authorization = "AWS4-HMAC-SHA256 "
      .. "Credential=AKIDEXAMPLE/20150830/us-east-1/sts/aws4_request, "
      .. "SignedHeaders=content-length;content-type;host;x-amz-date;"
      .. "x-amz-security-token;x-mongodb-gs2-cb-flag;"
      .. "x-mongodb-server-nonce, "
      .. "Signature=334f19c7dfaf6b58df2b3d22c02c30b67c0db925aa681b82ba7e9f9d2ccc9275"
    local runtime = runtime_with_nonce(client_nonce)
    local step = 0
    local commands = {
      command = function(_, _, body)
        step = step + 1

        if step == 1 then
          return server_first(client_nonce)
        end

        local payload = assert(bson.decode(body:get("payload").data))

        assert.are.equal(expected_authorization, payload:get("a"))
        assert.are.equal("TOKEN", payload:get("t"))
        return bson.document({
          { "conversationId", 7 },
          { "done", true },
          { "payload", bson.binary("") },
          { "ok", 1 },
        })
      end,
    }

    assert.is_true(aws.authenticate(
      commands,
      runtime,
      resolved_credentials("TOKEN")
    ))
  end)

  it("resolves environment credentials before the SASL conversation", function()
    local client_nonce = string.rep("0", 32)
    local runtime = runtime_with_nonce(client_nonce, {
      AWS_ACCESS_KEY_ID = "AKIDEXAMPLE",
      AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    })
    local step = 0
    local commands = {
      command = function(_, _, body)
        step = step + 1

        if step == 1 then
          return server_first(client_nonce)
        end

        local payload = assert(bson.decode(body:get("payload").data))

        assert.is_not_nil(payload:get("a"):find(
          "Credential=AKIDEXAMPLE/",
          1,
          true
        ))
        assert.is_nil(body:get("payload").data:find("EXAMPLEKEY", 1, true))
        return bson.document({
          { "conversationId", 7 },
          { "done", true },
          { "payload", bson.binary("") },
          { "ok", 1 },
        })
      end,
    }

    assert.is_true(auth.authenticate(commands, runtime, {
      mechanism = "MONGODB-AWS",
      source = "$external",
    }, { mechanism = "MONGODB-AWS" }))
    assert.are.equal(2, step)
  end)

  it("derives regional STS scopes from the server host", function()
    local client_nonce = string.rep("0", 32)
    local runtime = runtime_with_nonce(client_nonce)
    local commands = {
      command = function(_, _, body)
        if body:get("saslStart") ~= nil then
          return server_first(client_nonce, "sts.us-west-2.amazonaws.com")
        end

        local payload = assert(bson.decode(body:get("payload").data))

        assert.is_not_nil(payload:get("a"):find(
          "/20150830/us-west-2/sts/aws4_request",
          1,
          true
        ))
        return bson.document({
          { "conversationId", 7 },
          { "done", true },
          { "payload", bson.binary("") },
          { "ok", 1 },
        })
      end,
    }

    assert.is_true(aws.authenticate(commands, runtime, resolved_credentials()))
  end)

  it("rejects invalid server nonces and STS hosts before signing", function()
    local client_nonce = string.rep("0", 32)
    local cases = {
      {
        host = "sts.amazonaws.com",
        nonce = client_nonce .. string.rep("1", 31),
      },
      {
        host = "sts.amazonaws.com",
        nonce = string.rep("x", 64),
      },
      { host = "", nonce = client_nonce .. string.rep("1", 32) },
      { host = ".amazonaws.com", nonce = client_nonce .. string.rep("1", 32) },
      { host = "sts..amazonaws.com", nonce = client_nonce .. string.rep("1", 32) },
      { host = "sts.amazonaws.", nonce = client_nonce .. string.rep("1", 32) },
      { host = string.rep("x", 256), nonce = client_nonce .. string.rep("1", 32) },
    }

    for _, case in ipairs(cases) do
      local runtime = runtime_with_nonce(client_nonce)
      local commands = {
        command = function()
          return server_first(client_nonce, case.host, case.nonce)
        end,
      }
      local authenticated, err = aws.authenticate(
        commands,
        runtime,
        resolved_credentials()
      )

      assert.is_nil(authenticated)
      assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    end
  end)

  it("rejects malformed SASL payloads and redacts command failures", function()
    local client_nonce = string.rep("0", 32)
    local runtime = runtime_with_nonce(client_nonce)
    local commands = {
      command = function()
        return bson.document({
          { "conversationId", 7 },
          { "done", false },
          { "payload", bson.binary("not BSON") },
          { "ok", 1 },
        })
      end,
    }
    local authenticated, err = aws.authenticate(
      commands,
      runtime,
      resolved_credentials()
    )

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))

    runtime = runtime_with_nonce(client_nonce)
    commands.command = function()
      return nil, errors.new({
        category = errors.CATEGORY.SERVER,
        code = 18,
        message = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY TOKEN",
      })
    end
    authenticated, err = aws.authenticate(
      commands,
      runtime,
      resolved_credentials("TOKEN")
    )

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal(18, err.code)
    assert.is_nil(tostring(err):find("EXAMPLEKEY", 1, true))
    assert.is_nil(tostring(err):find("TOKEN", 1, true))
  end)
end)
