local auth = require("mongodb.auth")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local TOKEN_PATH = "/private/oidc-token"

local function credentials()
  return {
    mechanism = "MONGODB-OIDC",
    mechanism_properties = { ENVIRONMENT = "test" },
    source = "$external",
  }
end

local function response()
  return bson.document({
    { "conversationId", 7 },
    { "payload", bson.binary("") },
    { "done", true },
    { "ok", 1 },
  })
end

describe("MONGODB-OIDC built-in providers", function()
  it("authenticates the test environment token through runtime adapters", function()
    local runtime = fake_runtime.new({
      environment = { OIDC_TOKEN_FILE = TOKEN_PATH },
      files = { [TOKEN_PATH] = "  private-access-token\n" },
      now = 10,
    })
    local cancellation = runtime.cancellation:new()
    local commands = 0
    local connection = {
      command = function(_, _, body)
        commands = commands + 1
        local payload = assert(bson.decode(body:get("payload").data))

        assert.are.equal("saslStart", body:keys()[1])
        assert.are.equal("private-access-token", payload:get("jwt"))
        return response()
      end,
    }

    assert.is_true(auth.authenticate(
      connection,
      runtime,
      credentials(),
      {
        cancellation = cancellation,
        deadline = 30,
      }
    ))
    assert.are.same({ "OIDC_TOKEN_FILE" }, runtime.calls.environment)
    assert.are.equal(TOKEN_PATH, runtime.calls.file[1].path)
    assert.are.equal(30, runtime.calls.file[1].options.deadline)
    assert.are.equal(cancellation, runtime.calls.file[1].options.cancellation)
    assert.are.equal(1024 * 1024, runtime.calls.file[1].options.max_bytes)
    assert.are.equal(0, #runtime.calls.http)
    assert.are.equal(1, commands)
  end)

  it("rejects missing, unreadable, empty, and oversized test tokens", function()
    local cases = {
      { environment = {} },
      { environment = { OIDC_TOKEN_FILE = "" } },
      { environment = { OIDC_TOKEN_FILE = TOKEN_PATH } },
      {
        environment = { OIDC_TOKEN_FILE = TOKEN_PATH },
        files = { [TOKEN_PATH] = " \n\t" },
      },
      {
        environment = { OIDC_TOKEN_FILE = TOKEN_PATH },
        files = { [TOKEN_PATH] = string.rep("x", 1024 * 1024 + 1) },
      },
    }

    for _, case in ipairs(cases) do
      local runtime = fake_runtime.new(case)
      local commands = 0
      local authenticated, err = auth.authenticate({
        command = function()
          commands = commands + 1
          return response()
        end,
      }, runtime, credentials())

      assert.is_nil(authenticated)
      assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
      assert.are.equal("test", err.details.provider)
      assert.is_nil(tostring(err):find(TOKEN_PATH, 1, true))
      assert.is_nil(tostring(err):find("private", 1, true))
      assert.are.equal(0, #runtime.calls.http)
      assert.are.equal(0, commands)
    end
  end)

  it("keeps test tokens out of authentication failures", function()
    local runtime = fake_runtime.new({
      environment = { OIDC_TOKEN_FILE = TOKEN_PATH },
      files = { [TOKEN_PATH] = "private-access-token" },
    })
    local authenticated, err = auth.authenticate({
      command = function()
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          code = 18,
          message = "private-access-token rejected",
        })
      end,
    }, runtime, credentials())

    assert.is_nil(authenticated)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal(18, err.code)
    assert.is_nil(tostring(err):find("private-access-token", 1, true))
    assert.are.equal(0, #runtime.calls.http)
  end)
end)
