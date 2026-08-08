local bson = require("mongodb.bson")
local metadata = require("mongodb.handshake.metadata")

local function environment_snapshot(value)
  local environment = value:get("env")

  if environment == nil then
    return nil
  end

  local result = {}

  for key, item in environment:iter() do
    if bson.is_document(item) then
      local nested = {}

      for nested_key, nested_value in item:iter() do
        nested[nested_key] = nested_value
      end

      result[key] = nested
    elseif bson.is_exact(item) then
      result[key] = item:to_number()
    else
      result[key] = item
    end
  end

  return result
end

describe("handshake client metadata", function()
  it("builds immutable baseline metadata from client and runtime facts", function()
    local value = metadata.new({
      app_name = "metadata-spec",
      os = {
        architecture = "test-arch",
        name = "Test OS",
        type = "test-os",
        version = "1.0",
      },
      platform = "Lua 5.4 test-runtime",
    })

    assert.are.same({ "application", "driver", "os", "platform" }, value:keys())
    assert.are.equal("metadata-spec", value:get("application"):get("name"))
    assert.are.equal("lua-mongodb", value:get("driver"):get("name"))
    assert.are.equal("0.1.0-dev", value:get("driver"):get("version"))
    assert.are.same(
      { "type", "name", "architecture", "version" },
      value:get("os"):keys()
    )
    assert.are.equal("test-os", value:get("os"):get("type"))
    assert.are.equal("Test OS", value:get("os"):get("name"))
    assert.are.equal("test-arch", value:get("os"):get("architecture"))
    assert.are.equal("1.0", value:get("os"):get("version"))
    assert.are.equal("Lua 5.4 test-runtime", value:get("platform"))

    local fallback = metadata.new({ platform = "" })

    assert.are.same({ "driver", "os" }, fallback:keys())
    assert.are.equal("unknown", fallback:get("os"):get("type"))
    assert.has_error(function()
      value.extra = true
    end, "BSON values are immutable")
  end)

  it("captures FaaS and container facts from an injected runtime snapshot", function()
    local cases = {
      {
        environment = {
          AWS_EXECUTION_ENV = "AWS_Lambda_java8",
          AWS_LAMBDA_FUNCTION_MEMORY_SIZE = "1024",
          AWS_REGION = "us-east-2",
        },
        expected = {
          memory_mb = 1024,
          name = "aws.lambda",
          region = "us-east-2",
        },
      },
      {
        environment = { AWS_LAMBDA_RUNTIME_API = "127.0.0.1:9001" },
        expected = { name = "aws.lambda" },
      },
      {
        environment = { FUNCTIONS_WORKER_RUNTIME = "node" },
        expected = { name = "azure.func" },
      },
      {
        environment = {
          FUNCTION_MEMORY_MB = "1024",
          FUNCTION_REGION = "us-central1",
          FUNCTION_TIMEOUT_SEC = "60",
          K_SERVICE = "servicename",
        },
        expected = {
          memory_mb = 1024,
          name = "gcp.func",
          region = "us-central1",
          timeout_sec = 60,
        },
      },
      {
        environment = { FUNCTION_NAME = "function-name" },
        expected = { name = "gcp.func" },
      },
      {
        environment = { VERCEL = "1", VERCEL_REGION = "cdg1" },
        expected = { name = "vercel", region = "cdg1" },
      },
      {
        environment = {
          AWS_EXECUTION_ENV = "AWS_Lambda_java8",
          AWS_REGION = "us-east-2",
          VERCEL = "1",
          VERCEL_REGION = "cdg1",
        },
        expected = { name = "vercel", region = "cdg1" },
      },
      {
        environment = {
          AWS_EXECUTION_ENV = "AWS_Lambda_java8",
          FUNCTIONS_WORKER_RUNTIME = "node",
        },
      },
      {
        environment = {
          AWS_EXECUTION_ENV = "AWS_Lambda_java8",
          AWS_LAMBDA_FUNCTION_MEMORY_SIZE = "big",
        },
        expected = { name = "aws.lambda" },
      },
      {
        environment = { AWS_EXECUTION_ENV = "EC2" },
      },
      {
        expected = { container = { runtime = "docker" } },
        files = { ["/.dockerenv"] = true },
      },
      {
        environment = { KUBERNETES_SERVICE_HOST = "1" },
        expected = { container = { orchestrator = "kubernetes" } },
      },
      {
        environment = {
          AWS_EXECUTION_ENV = "AWS_Lambda_java8",
          AWS_LAMBDA_FUNCTION_MEMORY_SIZE = "1024",
          AWS_REGION = "us-east-2",
          KUBERNETES_SERVICE_HOST = "1",
        },
        expected = {
          container = { orchestrator = "kubernetes" },
          memory_mb = 1024,
          name = "aws.lambda",
          region = "us-east-2",
        },
      },
    }

    for _, test_case in ipairs(cases) do
      local value = metadata.new({
        environment = test_case.environment,
        files = test_case.files,
        platform = "",
      })

      assert.are.same(test_case.expected, environment_snapshot(value))
    end
  end)
end)
