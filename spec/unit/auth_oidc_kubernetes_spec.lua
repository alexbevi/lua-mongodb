local auth = require("mongodb.auth")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

local DEFAULT_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"

local function credentials()
  return {
    mechanism = "MONGODB-OIDC",
    mechanism_properties = { ENVIRONMENT = "k8s" },
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

describe("MONGODB-OIDC Kubernetes provider", function()
  it("prefers the AKS token file and preserves its contents", function()
    local runtime = fake_runtime.new({
      environment = {
        AZURE_FEDERATED_TOKEN_FILE = "/private/aks-token",
        AWS_WEB_IDENTITY_TOKEN_FILE = "/private/eks-token",
      },
      files = {
        ["/private/aks-token"] = "private-k8s-token\n",
        ["/private/eks-token"] = "wrong-token",
      },
      now = 10,
    })
    local cancellation = runtime.cancellation:new()
    local commands = 0
    local connection = {
      command = function(_, _, body)
        commands = commands + 1
        local payload = assert(bson.decode(body:get("payload").data))

        assert.are.equal("private-k8s-token\n", payload:get("jwt"))
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
    assert.are.same({ "AZURE_FEDERATED_TOKEN_FILE" }, runtime.calls.environment)
    assert.are.equal("/private/aks-token", runtime.calls.file[1].path)
    assert.are.equal(30, runtime.calls.file[1].options.deadline)
    assert.are.equal(cancellation, runtime.calls.file[1].options.cancellation)
    assert.are.equal(1, commands)
  end)

  it("falls back from the EKS token file to the service-account path", function()
    local cases = {
      {
        environment = { AWS_WEB_IDENTITY_TOKEN_FILE = "/private/eks-token" },
        path = "/private/eks-token",
        token = "private-eks-token",
      },
      {
        environment = {},
        path = DEFAULT_TOKEN_PATH,
        token = "private-service-account-token",
      },
    }

    for _, case in ipairs(cases) do
      local runtime = fake_runtime.new({
        environment = case.environment,
        files = { [case.path] = case.token },
      })
      local actual_token

      assert.is_true(auth.authenticate({
        command = function(_, _, body)
          local payload = assert(bson.decode(body:get("payload").data))

          actual_token = payload:get("jwt")
          return response()
        end,
      }, runtime, credentials()))
      assert.are.equal(case.token, actual_token)
      assert.are.equal(case.path, runtime.calls.file[1].path)
      assert.are.same({
        "AZURE_FEDERATED_TOKEN_FILE",
        "AWS_WEB_IDENTITY_TOKEN_FILE",
      }, runtime.calls.environment)
    end
  end)

  it("rejects empty paths, unreadable files, and empty tokens", function()
    local cases = {
      {
        environment = {
          AZURE_FEDERATED_TOKEN_FILE = "",
          AWS_WEB_IDENTITY_TOKEN_FILE = "/private/ignored-token",
        },
      },
      { environment = { AWS_WEB_IDENTITY_TOKEN_FILE = "" } },
      { environment = {} },
      {
        environment = { AWS_WEB_IDENTITY_TOKEN_FILE = "/private/empty-token" },
        files = { ["/private/empty-token"] = "" },
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
      assert.are.equal("k8s", err.details.provider)
      assert.is_nil(tostring(err):find("private", 1, true))
      assert.are.equal(0, commands)
    end
  end)
end)
