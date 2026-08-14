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

  it("fetches temporary credentials from a configured HTTPS full URI", function()
    local runtime = configured_runtime({
      environment = {
        AWS_CONTAINER_CREDENTIALS_FULL_URI =
          "https://credentials.example.test/v1/task",
      },
    })

    runtime:queue_http(response(valid_body()))

    assert(ecs.resolve(runtime))
    assert.are.equal(
      "https://credentials.example.test/v1/task",
      runtime.calls.http[1].request.url
    )
  end)

  it("authorizes full-URI requests with a plaintext token", function()
    local runtime = configured_runtime({
      environment = {
        AWS_CONTAINER_AUTHORIZATION_TOKEN = "Bearer container-secret",
        AWS_CONTAINER_CREDENTIALS_FULL_URI =
          "https://credentials.example.test/v1/task",
      },
    })

    runtime:queue_http(response(valid_body()))

    assert(ecs.resolve(runtime))
    assert.are.same({
      authorization = "Bearer container-secret",
    }, runtime.calls.http[1].request.headers)
    assert.are.equal(0, #runtime.calls.file)
  end)

  it("prefers a bounded file-backed authorization token", function()
    local runtime = configured_runtime({
      environment = {
        AWS_CONTAINER_AUTHORIZATION_TOKEN = "Bearer ignored-secret",
        AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE = "/var/run/container-token",
        AWS_CONTAINER_CREDENTIALS_FULL_URI =
          "https://credentials.example.test/v1/task",
      },
    })

    runtime:set_file("/var/run/container-token", "Bearer file-secret")
    runtime:queue_http(response(valid_body()))

    assert(ecs.resolve(runtime))
    assert.are.same({
      authorization = "Bearer file-secret",
    }, runtime.calls.http[1].request.headers)
    assert.are.equal("/var/run/container-token", runtime.calls.file[1].path)
    assert.are.equal(64 * 1024, runtime.calls.file[1].options.max_bytes)
    assert.are.equal(12, runtime.calls.file[1].options.deadline)
  end)

  it("ignores full-URI authorization inputs for a relative endpoint", function()
    local runtime = configured_runtime({
      environment = {
        AWS_CONTAINER_AUTHORIZATION_TOKEN = "Bearer ignored-secret",
        AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE = "/missing-token",
        AWS_CONTAINER_CREDENTIALS_FULL_URI =
          "https://credentials.example.test/ignored",
        AWS_CONTAINER_CREDENTIALS_RELATIVE_URI = RELATIVE_URI,
      },
    })

    runtime:queue_http(response(valid_body()))

    assert(ecs.resolve(runtime))
    assert.is_nil(runtime.calls.http[1].request.headers)
    assert.are.equal(0, #runtime.calls.file)
  end)

  it("rejects invalid authorization sources before networking", function()
    local cases = {
      { token = "" },
      { token = "Bearer line\nbreak" },
      { token_file = "" },
      {
        token = "Bearer must-not-fallback",
        token_file = "/missing-token",
      },
      { file_value = "", token_file = "/empty-token" },
      {
        file_value = string.rep("x", 64 * 1024 + 1),
        token_file = "/oversized-token",
      },
      {
        file_value = "Bearer line\nbreak",
        token_file = "/invalid-token",
      },
    }

    for _, case in ipairs(cases) do
      local runtime = configured_runtime({
        environment = {
          AWS_CONTAINER_AUTHORIZATION_TOKEN = case.token,
          AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE = case.token_file,
          AWS_CONTAINER_CREDENTIALS_FULL_URI =
            "https://credentials.example.test/v1/task",
        },
      })

      if case.file_value ~= nil then
        runtime:set_file(case.token_file, case.file_value)
      end

      local credential, err = ecs.resolve(runtime)

      assert.is_nil(credential)
      assert_auth_error(err)
      assert.are.equal(0, #runtime.calls.http)
      assert.is_nil(tostring(err):find("must-not-fallback", 1, true))
      assert.is_nil(tostring(err):find("missing-token", 1, true))
    end
  end)

  it("preserves token-file timeout and cancellation classifications", function()
    local runtime = configured_runtime({
      environment = {
        AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE = "/container-token",
        AWS_CONTAINER_CREDENTIALS_FULL_URI =
          "https://credentials.example.test/v1/task",
      },
    })

    runtime:set_file("/container-token", "Bearer secret")

    local credential, err = ecs.resolve(runtime, { deadline = 2 })

    assert.is_nil(credential)
    assert_auth_error(err)
    assert.is_true(err.timeout)
    assert.are.equal(errors.CATEGORY.TIMEOUT, err.details.source_category)
    assert.are.equal(0, #runtime.calls.http)

    runtime = configured_runtime({
      environment = {
        AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE = "/container-token",
        AWS_CONTAINER_CREDENTIALS_FULL_URI =
          "https://credentials.example.test/v1/task",
      },
    })
    runtime:set_file("/container-token", "Bearer secret")

    local cancellation = runtime.cancellation:new()

    cancellation:cancel("container token secret")
    credential, err = ecs.resolve(runtime, { cancellation = cancellation })

    assert.is_nil(credential)
    assert_auth_error(err)
    assert.are.equal(errors.CATEGORY.CANCELLED, err.details.source_category)
    assert.is_nil(tostring(err):find("container token secret", 1, true))
    assert.are.equal(0, #runtime.calls.http)
  end)

  it("permits local HTTP container credential endpoints", function()
    local urls = {
      "http://localhost:8080/v1/task",
      "http://127.12.34.56/v1/task",
      "http://169.254.170.2/v1/task",
      "http://169.254.170.23/v1/task",
      "http://[::1]:8080/v1/task",
      "http://[0:0:0:0:0:0:0:1]/v1/task",
      "http://[fd00:ec2::23]/v1/task",
    }

    for _, url in ipairs(urls) do
      local runtime = configured_runtime({
        environment = { AWS_CONTAINER_CREDENTIALS_FULL_URI = url },
      })

      runtime:queue_http(response(valid_body()))

      assert(ecs.resolve(runtime))
      assert.are.equal(url, runtime.calls.http[1].request.url)
    end
  end)

  it("prefers the relative URI over a configured full URI", function()
    local runtime = configured_runtime({
      environment = {
        AWS_CONTAINER_CREDENTIALS_FULL_URI =
          "http://attacker.example/ignored",
        AWS_CONTAINER_CREDENTIALS_RELATIVE_URI = RELATIVE_URI,
      },
    })

    runtime:queue_http(response(valid_body()))

    assert(ecs.resolve(runtime))
    assert.are.equal(
      "http://169.254.170.2" .. RELATIVE_URI,
      runtime.calls.http[1].request.url
    )
  end)

  it("rejects unsafe and malformed full URIs before networking", function()
    local urls = {
      "",
      "http://credentials.example.test/v1/task",
      "http://localhost.example/v1/task",
      "http://169.254.169.254/v1/task",
      "http://[::2]/v1/task",
      "http://[1:::2]/v1/task",
      "http://user@localhost/v1/task",
      "http://localhost:0/v1/task",
      "http://localhost/v1/task#fragment",
      "https://user@credentials.example.test/v1/task",
      "https://bad host/v1/task",
      "https://[not-ip]/v1/task",
      "https://credentials..example/v1/task",
      "ftp://localhost/v1/task",
    }

    for _, url in ipairs(urls) do
      local runtime = configured_runtime({
        environment = { AWS_CONTAINER_CREDENTIALS_FULL_URI = url },
      })
      local credential, err = ecs.resolve(runtime)

      assert.is_true(ecs.is_configured(runtime))
      assert.is_nil(credential)
      assert_auth_error(err)
      assert.are.equal(0, #runtime.calls.http)
    end
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
