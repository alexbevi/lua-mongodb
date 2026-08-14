local ecs = require("mongodb.auth.aws_ecs")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local RELATIVE_URI = "/v2/credentials/task-id"

local function configured_runtime(options)
  options = options or {}
  options.environment = options.environment or {
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI = RELATIVE_URI,
  }
  options.now = options.now or 2
  options.wall_time = options.wall_time or 1700000000
  return fake_runtime.new(options)
end

local function valid_body(expiration)
  return "{\"AccessKeyId\":\"ACCESS\","
    .. "\"Expiration\":\""
    .. (expiration or "2023-11-14T23:13:20Z")
    .. "\",\"RoleArn\":\"arn:aws:iam::123456789012:role/task\","
    .. "\"SecretAccessKey\":\"SECRET\",\"Token\":\"TOKEN\"}"
end

local function response(body, status)
  return {
    body = body,
    headers = { ["content-type"] = "application/json" },
    status = status or 200,
  }
end

local function assert_auth_error(err)
  assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
  assert.are.equal("ecs", err.details.provider)
  assert.is_nil(tostring(err):find("ACCESS", 1, true))
  assert.is_nil(tostring(err):find("SECRET", 1, true))
  assert.is_nil(tostring(err):find("TOKEN", 1, true))
end

describe("MONGODB-AWS ECS credentials", function()
  it("fetches temporary credentials from the configured relative URI", function()
    local runtime = configured_runtime()

    runtime:queue_http(response(valid_body()))

    local credential = assert(ecs.resolve(runtime))

    assert.are.same({
      expiration = 1700003600,
      password = "SECRET",
      session_token = "TOKEN",
      username = "ACCESS",
    }, credential)
    assert.are.same({
      method = "GET",
      url = "http://169.254.170.2/v2/credentials/task-id",
    }, runtime.calls.http[1].request)
    assert.are.equal(12, runtime.calls.http[1].deadline)
  end)

  it("caps requests to ten seconds and preserves an earlier deadline", function()
    local runtime = configured_runtime()
    local cancellation = runtime.cancellation:new()

    runtime:queue_http(response(valid_body("2023-11-14T23:13:20.500Z")))

    assert(ecs.resolve(runtime, {
      cancellation = cancellation,
      deadline = 5,
    }))
    assert.are.equal(5, runtime.calls.http[1].deadline)
    assert.are.equal(cancellation, runtime.calls.http[1].cancellation)
  end)

  it("rejects malformed relative URIs before networking", function()
    local cases = {
      "",
      "v2/credentials/task-id",
      "http://attacker.example/credentials",
      "/credentials#fragment",
      "/credentials\nAuthorization: secret",
    }

    for _, relative_uri in ipairs(cases) do
      local runtime = configured_runtime({
        environment = {
          AWS_CONTAINER_CREDENTIALS_RELATIVE_URI = relative_uri,
        },
      })
      local credential, err = ecs.resolve(runtime)

      assert.is_true(ecs.is_configured(runtime))
      assert.is_nil(credential)
      assert_auth_error(err)
      assert.are.equal(0, #runtime.calls.http)
    end

    local runtime = fake_runtime.new()

    assert.is_false(ecs.is_configured(runtime))
  end)

  it("rejects malformed, failed, and expired credential responses", function()
    local bodies = {
      "not json",
      "{}",
      "{\"AccessKeyId\":\"\",\"Expiration\":"
        .. "\"2023-11-14T23:13:20Z\",\"SecretAccessKey\":\"SECRET\","
        .. "\"Token\":\"TOKEN\"}",
      valid_body("2023-02-30T12:00:00Z"),
      valid_body("2023-11-14T22:13:20Z"),
    }

    for _, body in ipairs(bodies) do
      local runtime = configured_runtime()

      runtime:queue_http(response(body))

      local credential, err = ecs.resolve(runtime)

      assert.is_nil(credential)
      assert_auth_error(err)
    end

    local runtime = configured_runtime()

    runtime:queue_http(response("provider response secret", 500))

    local credential, err = ecs.resolve(runtime)

    assert.is_nil(credential)
    assert_auth_error(err)
    assert.is_nil(tostring(err):find("provider response secret", 1, true))
  end)

  it("preserves timeout and cancellation classifications", function()
    local failures = {
      errors.new({
        category = errors.CATEGORY.TIMEOUT,
        message = "timeout response secret",
      }),
      errors.new({
        category = errors.CATEGORY.CANCELLED,
        message = "cancellation response secret",
      }),
    }

    for _, failure in ipairs(failures) do
      local runtime = configured_runtime()

      runtime:queue_http(failure)

      local credential, err = ecs.resolve(runtime)

      assert.is_nil(credential)
      assert_auth_error(err)
      assert.are.equal(failure.category, err.details.source_category)
      assert.are.equal(failure.timeout, err.timeout)
      assert.is_nil(tostring(err):find(failure.message, 1, true))
    end

    local runtime = configured_runtime()
    local cancellation = runtime.cancellation:new()

    cancellation:cancel("cancelled before request secret")

    local credential, err = ecs.resolve(runtime, {
      cancellation = cancellation,
    })

    assert.is_nil(credential)
    assert_auth_error(err)
    assert.are.equal(errors.CATEGORY.CANCELLED, err.details.source_category)
    assert.are.equal(0, #runtime.calls.http)
  end)
end)
