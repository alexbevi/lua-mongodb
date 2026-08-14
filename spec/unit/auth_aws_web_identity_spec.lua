local web_identity = require("mongodb.auth.aws_web_identity")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local TOKEN_PATH = "/var/run/secrets/aws-token"

local function configured_runtime(options)
  options = options or {}
  options.environment = options.environment or {
    AWS_ROLE_ARN = "arn:aws:iam::123456789012:role/My Role",
    AWS_ROLE_SESSION_NAME = "session/name",
    AWS_WEB_IDENTITY_TOKEN_FILE = TOKEN_PATH,
  }
  options.wall_time = options.wall_time or 1700000000

  local runtime = fake_runtime.new(options)

  runtime:set_file(TOKEN_PATH, "header.payload+signature\n")
  return runtime
end

local function response(body, status)
  return {
    body = body,
    headers = { ["content-type"] = "application/json" },
    status = status or 200,
  }
end

local function valid_body(expiration)
  return ("{\"Credentials\":{\"AccessKeyId\":\"ACCESS\","
    .. "\"Expiration\":\"%s\",\"SecretAccessKey\":\"SECRET\","
    .. "\"SessionToken\":\"TOKEN\"}}"):format(
      expiration or "2023-11-14T23:13:20Z"
    )
end

local function assert_auth_error(err)
  assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
  assert.are.equal("web_identity", err.details.provider)
  assert.is_nil(tostring(err):find("ACCESS", 1, true))
  assert.is_nil(tostring(err):find("SECRET", 1, true))
  assert.is_nil(tostring(err):find("TOKEN", 1, true))
end

describe("MONGODB-AWS web identity credentials", function()
  it("exchanges the configured token for temporary credentials", function()
    local runtime = configured_runtime()

    runtime:queue_http(response(valid_body()))

    local credential = assert(web_identity.resolve(runtime))

    assert.are.equal("ACCESS", credential.username)
    assert.are.equal("SECRET", credential.password)
    assert.are.equal("TOKEN", credential.session_token)
    assert.are.equal(1700003600, credential.expiration)
    assert.are.same({
      body = "",
      headers = { accept = "application/json" },
      method = "POST",
      url = "https://sts.amazonaws.com/"
        .. "?Action=AssumeRoleWithWebIdentity"
        .. "&RoleSessionName=session%2Fname"
        .. "&RoleArn=arn%3Aaws%3Aiam%3A%3A123456789012%3Arole%2FMy%20Role"
        .. "&WebIdentityToken=header.payload%2Bsignature%0A"
        .. "&Version=2011-06-15",
    }, runtime.calls.http[1].request)
    assert.are.equal(TOKEN_PATH, runtime.calls.file[1].path)
    assert.are.equal(1024 * 1024, runtime.calls.file[1].options.max_bytes)
  end)

  it("generates a session name and accepts fractional UTC expiration", function()
    local runtime = configured_runtime({
      entropy = string.rep("\1", 16),
      environment = {
        AWS_ROLE_ARN = "role",
        AWS_WEB_IDENTITY_TOKEN_FILE = TOKEN_PATH,
      },
    })

    runtime:queue_http(response(valid_body("2023-11-14T23:13:20.500Z")))

    assert(web_identity.resolve(runtime))
    assert.is_not_nil(runtime.calls.http[1].request.url:find(
      "RoleSessionName=lua-mongodb-" .. string.rep("01", 16),
      1,
      true
    ))
  end)

  it("rejects incomplete configuration and unreadable token files", function()
    local cases = {
      {
        configured = false,
        environment = { AWS_ROLE_ARN = "role" },
      },
      {
        configured = false,
        environment = { AWS_WEB_IDENTITY_TOKEN_FILE = TOKEN_PATH },
      },
      {
        configured = true,
        environment = {
          AWS_ROLE_ARN = "role",
          AWS_ROLE_SESSION_NAME = "",
          AWS_WEB_IDENTITY_TOKEN_FILE = TOKEN_PATH,
        },
      },
    }

    for _, case in ipairs(cases) do
      local runtime = fake_runtime.new({ environment = case.environment })
      local credential, err = web_identity.resolve(runtime)

      assert.are.equal(case.configured, web_identity.is_configured(runtime))
      assert.is_nil(credential)
      assert_auth_error(err)
      assert.are.equal(0, #runtime.calls.http)
    end

    local runtime = configured_runtime()

    assert.is_true(web_identity.is_configured(runtime))
    runtime:set_file(TOKEN_PATH, nil)

    local credential, err = web_identity.resolve(runtime)

    assert.is_nil(credential)
    assert_auth_error(err)
    assert.is_nil(tostring(err):find(TOKEN_PATH, 1, true))
  end)

  it("rejects malformed, failed, and expired STS responses", function()
    local bodies = {
      "not json",
      "{}",
      "{\"Credentials\":{\"AccessKeyId\":\"\","
        .. "\"Expiration\":\"2023-11-14T23:13:20Z\","
        .. "\"SecretAccessKey\":\"SECRET\",\"SessionToken\":\"TOKEN\"}}",
      valid_body("2023-02-30T12:00:00Z"),
      valid_body("2023-11-14T22:13:20Z"),
    }

    for _, body in ipairs(bodies) do
      local runtime = configured_runtime()

      runtime:queue_http(response(body))

      local credential, err = web_identity.resolve(runtime)

      assert.is_nil(credential)
      assert_auth_error(err)
    end

    local runtime = configured_runtime()

    runtime:queue_http(response("provider secret", 403))

    local credential, err = web_identity.resolve(runtime)

    assert.is_nil(credential)
    assert_auth_error(err)
    assert.is_nil(tostring(err):find("provider secret", 1, true))
  end)

  it("preserves timeout and cancellation classification without secrets", function()
    local runtime = configured_runtime({ now = 5 })
    local credential, err = web_identity.resolve(runtime, { deadline = 5 })

    assert.is_nil(credential)
    assert_auth_error(err)
    assert.is_true(err.timeout)
    assert.are.equal(errors.CATEGORY.TIMEOUT, err.details.source_category)

    runtime = configured_runtime()

    local cancellation = runtime.cancellation:new()

    cancellation:cancel("provider token secret")
    credential, err = web_identity.resolve(runtime, {
      cancellation = cancellation,
    })

    assert.is_nil(credential)
    assert_auth_error(err)
    assert.are.equal(errors.CATEGORY.CANCELLED, err.details.source_category)
    assert.is_nil(tostring(err):find("provider token secret", 1, true))

    local failures = {
      errors.new({
        category = errors.CATEGORY.TIMEOUT,
        message = "HTTP timeout secret",
      }),
      errors.new({
        category = errors.CATEGORY.CANCELLED,
        message = "HTTP cancellation secret",
      }),
    }

    for _, failure in ipairs(failures) do
      runtime = configured_runtime()
      runtime:queue_http(failure)

      credential, err = web_identity.resolve(runtime)

      assert.is_nil(credential)
      assert_auth_error(err)
      assert.are.equal(failure.category, err.details.source_category)
      assert.are.equal(failure.timeout, err.timeout)
      assert.is_nil(tostring(err):find(failure.message, 1, true))
    end
  end)
end)
