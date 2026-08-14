local auth = require("mongodb.auth")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local function credentials()
  return {
    mechanism = "MONGODB-OIDC",
    mechanism_properties = {
      ENVIRONMENT = "gcp",
      TOKEN_RESOURCE = "api://resource/audience?x=y",
    },
    source = "$external",
  }
end

local function metadata_response(body, status)
  return {
    body = body,
    headers = { ["content-type"] = "text/plain" },
    status = status or 200,
  }
end

local function sasl_response()
  return bson.document({
    { "conversationId", 7 },
    { "payload", bson.binary("") },
    { "done", true },
    { "ok", 1 },
  })
end

describe("MONGODB-OIDC GCP provider", function()
  it("authenticates the encoded audience from the metadata response", function()
    local runtime = fake_runtime.new({ now = 10 })
    local cancellation = runtime.cancellation:new()
    local commands = 0

    runtime:queue_http(metadata_response("private-gcp-token\n"))

    assert.is_true(auth.authenticate({
      command = function(_, _, body)
        commands = commands + 1
        local payload = assert(bson.decode(body:get("payload").data))

        assert.are.equal("private-gcp-token\n", payload:get("jwt"))
        return sasl_response()
      end,
    }, runtime, credentials(), {
      cancellation = cancellation,
      deadline = 30,
    }))
    assert.are.same({
      headers = { ["metadata-flavor"] = "Google" },
      max_response_bytes = 1024 * 1024,
      method = "GET",
      url = "http://metadata/computeMetadata/v1/instance/"
        .. "service-accounts/default/identity"
        .. "?audience=api%3A%2F%2Fresource%2Faudience%3Fx%3Dy",
    }, runtime.calls.http[1].request)
    assert.are.equal(30, runtime.calls.http[1].deadline)
    assert.are.equal(cancellation, runtime.calls.http[1].cancellation)
    assert.are.equal(1, commands)
  end)

  it("rejects malformed, failed, and empty metadata responses", function()
    local cases = {
      metadata_response("private provider response", 500),
      metadata_response("private-gcp-token", 201),
      metadata_response(""),
      { body = false, headers = {}, status = 200 },
      { body = "private-gcp-token", headers = {}, status = "200" },
    }

    for index, response in ipairs(cases) do
      local runtime = fake_runtime.new()
      local commands = 0

      runtime:queue_http(response)

      local authenticated, err = auth.authenticate({
        command = function()
          commands = commands + 1
          return sasl_response()
        end,
      }, runtime, credentials())

      assert.is_nil(authenticated)
      assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
      assert.are.equal("gcp", err.details.provider)
      assert.is_nil(tostring(err):find("private", 1, true))
      assert.are.equal(0, commands)

      if index == 1 then
        assert.are.equal("private provider response", err.details.response_body)
      end
    end
  end)

  it("preserves HTTP timeout and cancellation classifications", function()
    local failures = {
      errors.new({
        category = errors.CATEGORY.TIMEOUT,
        message = "private timeout",
      }),
      errors.new({
        category = errors.CATEGORY.CANCELLED,
        message = "private cancellation",
      }),
    }

    for _, failure in ipairs(failures) do
      local runtime = fake_runtime.new()
      local cancellation = runtime.cancellation:new()

      runtime:queue_http(failure)

      local authenticated, err = auth.authenticate({
        command = function()
          error("SASL must not run after provider failure")
        end,
      }, runtime, credentials(), { cancellation = cancellation })

      assert.is_nil(authenticated)
      assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
      assert.are.equal(failure.category, err.details.source_category)
      assert.are.equal(failure.timeout, err.timeout)
      assert.are.equal(cancellation, runtime.calls.http[1].cancellation)
      assert.is_nil(tostring(err):find("private", 1, true))
    end
  end)
end)
