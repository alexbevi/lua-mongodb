local ec2 = require("mongodb.auth.aws_ec2")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local function response(body, content_type, status)
  return {
    body = body,
    headers = { ["content-type"] = content_type or "text/plain" },
    status = status or 200,
  }
end

local function valid_body(expiration)
  return "{\"Code\":\"Success\",\"AccessKeyId\":\"ACCESS\","
    .. "\"Expiration\":\""
    .. (expiration or "2023-11-14T23:13:20Z")
    .. "\",\"SecretAccessKey\":\"SECRET\",\"Token\":\"TOKEN\"}"
end

local function configured_runtime(options)
  options = options or {}
  options.now = options.now or 2
  options.wall_time = options.wall_time or 1700000000
  return fake_runtime.new(options)
end

local function queue_valid(runtime, role, expiration)
  runtime:queue_http(response("IMDS_TOKEN"))
  runtime:queue_http(response(role or "database-role"))
  runtime:queue_http(response(
    valid_body(expiration),
    "application/json"
  ))
end

local function assert_auth_error(err)
  assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
  assert.are.equal("ec2", err.details.provider)
  assert.is_nil(tostring(err):find("ACCESS", 1, true))
  assert.is_nil(tostring(err):find("SECRET", 1, true))
  assert.is_nil(tostring(err):find("TOKEN", 1, true))
  assert.is_nil(tostring(err):find("database-role", 1, true))
end

describe("MONGODB-AWS EC2 credentials", function()
  it("resolves temporary credentials through IMDSv2", function()
    local runtime = configured_runtime()

    queue_valid(runtime)

    local credential = assert(ec2.resolve(runtime))

    assert.are.same({
      expiration = 1700003600,
      password = "SECRET",
      session_token = "TOKEN",
      username = "ACCESS",
    }, credential)
    assert.are.same({
      headers = { ["x-aws-ec2-metadata-token-ttl-seconds"] = "30" },
      max_response_bytes = 64 * 1024,
      method = "PUT",
      url = "http://169.254.169.254/latest/api/token",
    }, runtime.calls.http[1].request)
    assert.are.same({
      headers = { ["x-aws-ec2-metadata-token"] = "IMDS_TOKEN" },
      max_response_bytes = 1024,
      method = "GET",
      url = "http://169.254.169.254/latest/meta-data/iam/security-credentials/",
    }, runtime.calls.http[2].request)
    assert.are.same({
      headers = { ["x-aws-ec2-metadata-token"] = "IMDS_TOKEN" },
      max_response_bytes = 1024 * 1024,
      method = "GET",
      url = "http://169.254.169.254/latest/meta-data/iam/security-credentials/"
        .. "database-role",
    }, runtime.calls.http[3].request)

    for _, call in ipairs(runtime.calls.http) do
      assert.are.equal(12, call.deadline)
    end
  end)

  it("accepts a line-terminated role and fractional expiration", function()
    local runtime = configured_runtime()
    local cancellation = runtime.cancellation:new()

    queue_valid(runtime, "database-role\r\n", "2023-11-14T23:13:20.500Z")

    local credential = assert(ec2.resolve(runtime, {
      cancellation = cancellation,
      deadline = 5,
    }))

    assert.are.equal(1700003600, credential.expiration)
    assert.are.equal(
      "http://169.254.169.254/latest/meta-data/iam/security-credentials/"
        .. "database-role",
      runtime.calls.http[3].request.url
    )

    for _, call in ipairs(runtime.calls.http) do
      assert.are.equal(5, call.deadline)
      assert.are.equal(cancellation, call.cancellation)
    end
  end)

  it("rejects invalid IMDSv2 token responses before role discovery", function()
    local cases = {
      response("", nil),
      response("PRIVATE TOKEN", nil),
      response("PRIVATE_TOKEN\n", nil),
      response(string.rep("x", 64 * 1024 + 1), nil),
      response("PRIVATE_TOKEN", nil, 500),
    }

    for _, token_response in ipairs(cases) do
      local runtime = configured_runtime()

      runtime:queue_http(token_response)

      local credential, err = ec2.resolve(runtime)

      assert.is_nil(credential)
      assert_auth_error(err)
      assert.are.equal(1, #runtime.calls.http)
      assert.is_nil(tostring(err):find("PRIVATE", 1, true))
    end
  end)

  it("rejects invalid role responses before fetching credentials", function()
    local cases = {
      response(""),
      response("../PRIVATE_ROLE"),
      response("PRIVATE_ROLE\nSECOND_ROLE"),
      response(string.rep("x", 65)),
      response("PRIVATE_ROLE", nil, 500),
    }

    for _, role_response in ipairs(cases) do
      local runtime = configured_runtime()

      runtime:queue_http(response("IMDS_TOKEN"))
      runtime:queue_http(role_response)

      local credential, err = ec2.resolve(runtime)

      assert.is_nil(credential)
      assert_auth_error(err)
      assert.are.equal(2, #runtime.calls.http)
      assert.is_nil(tostring(err):find("PRIVATE", 1, true))
    end
  end)

  it("rejects malformed, failed, and expired credential responses", function()
    local bodies = {
      "not json",
      "{}",
      "{\"Code\":\"Failure\",\"AccessKeyId\":\"PRIVATE_ACCESS\","
        .. "\"SecretAccessKey\":\"PRIVATE_SECRET\","
        .. "\"Token\":\"PRIVATE_TOKEN\"}",
      "{\"Code\":\"Success\",\"AccessKeyId\":\"\","
        .. "\"Expiration\":\"2023-11-14T23:13:20Z\","
        .. "\"SecretAccessKey\":\"PRIVATE_SECRET\","
        .. "\"Token\":\"PRIVATE_TOKEN\"}",
      valid_body("2023-02-30T12:00:00Z"),
      valid_body("2023-11-14T22:13:20Z"),
      string.rep("x", 1024 * 1024 + 1),
    }

    for _, body in ipairs(bodies) do
      local runtime = configured_runtime()

      runtime:queue_http(response("IMDS_TOKEN"))
      runtime:queue_http(response("database-role"))
      runtime:queue_http(response(body, "application/json"))

      local credential, err = ec2.resolve(runtime)

      assert.is_nil(credential)
      assert_auth_error(err)
      assert.are.equal(3, #runtime.calls.http)
      assert.is_nil(tostring(err):find("PRIVATE", 1, true))
    end
  end)

  it("preserves provider timeout and cancellation classifications", function()
    local runtime = configured_runtime()
    local credential, err = ec2.resolve(runtime, { deadline = 2 })

    assert.is_nil(credential)
    assert_auth_error(err)
    assert.is_true(err.timeout)
    assert.are.equal(errors.CATEGORY.TIMEOUT, err.details.source_category)
    assert.are.equal(0, #runtime.calls.http)

    runtime = configured_runtime()

    local cancellation = runtime.cancellation:new()

    cancellation:cancel("PRIVATE cancellation reason")
    credential, err = ec2.resolve(runtime, { cancellation = cancellation })

    assert.is_nil(credential)
    assert_auth_error(err)
    assert.are.equal(errors.CATEGORY.CANCELLED, err.details.source_category)
    assert.is_nil(tostring(err):find("PRIVATE", 1, true))
    assert.are.equal(0, #runtime.calls.http)
  end)

  it("redacts transport failures from each IMDSv2 stage", function()
    local failure = errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "PRIVATE_TOKEN PRIVATE_ROLE PRIVATE_SECRET",
      retryable = true,
    })

    for stage = 1, 3 do
      local runtime = configured_runtime()

      if stage > 1 then
        runtime:queue_http(response("IMDS_TOKEN"))
      end

      if stage > 2 then
        runtime:queue_http(response("database-role"))
      end

      runtime:queue_http(failure)

      local credential, err = ec2.resolve(runtime)

      assert.is_nil(credential)
      assert_auth_error(err)
      assert.are.equal(errors.CATEGORY.NETWORK, err.details.source_category)
      assert.is_true(err.retryable)
      assert.are.equal(stage, #runtime.calls.http)
      assert.is_nil(tostring(err):find("PRIVATE", 1, true))
    end
  end)
end)
