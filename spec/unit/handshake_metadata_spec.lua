local bson = require("mongodb.bson")
local metadata = require("mongodb.handshake.metadata")

local function encoded_size(value)
  return #assert(bson.encode(value))
end

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
    assert.are.equal("0.3.0", value:get("driver"):get("version"))
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

  it("bounds oversized metadata in the normative reduction order", function()
    local env_reduced = metadata.new({
      environment = {
        AWS_EXECUTION_ENV = "AWS_Lambda_java8",
        AWS_LAMBDA_FUNCTION_MEMORY_SIZE = "1024",
        AWS_REGION = string.rep("r", 512),
        KUBERNETES_SERVICE_HOST = "1",
      },
      files = { ["/.dockerenv"] = true },
      os = {
        architecture = "test-arch",
        name = "Test OS",
        type = "test-os",
        version = "1.0",
      },
      platform = "test-platform",
    })

    assert.are.same({ name = "aws.lambda" }, environment_snapshot(env_reduced))
    assert.are.same(
      { "type", "name", "architecture", "version" },
      env_reduced:get("os"):keys()
    )

    local os_reduced = metadata.new({
      environment = {
        AWS_EXECUTION_ENV = "AWS_Lambda_java8",
        AWS_REGION = string.rep("r", 512),
      },
      os = {
        architecture = "test-arch",
        name = string.rep("o", 512),
        type = "test-os",
        version = "1.0",
      },
      platform = "test-platform",
    })

    assert.are.same({ name = "aws.lambda" }, environment_snapshot(os_reduced))
    assert.are.same({ "type" }, os_reduced:get("os"):keys())

    local exact_options = {
      app_name = string.rep("a", 128),
      os = { type = "test-os" },
      platform = string.rep("p", 254),
    }
    local exact = metadata.new(exact_options)

    assert.are.equal(512, encoded_size(exact))
    assert.are.equal(exact_options.platform, exact:get("platform"))

    exact_options.environment = {
      AWS_EXECUTION_ENV = "AWS_Lambda_java8",
      AWS_REGION = string.rep("r", 512),
    }

    local env_omitted = metadata.new(exact_options)

    assert.are.equal(512, encoded_size(env_omitted))
    assert.is_nil(env_omitted:get("env"))
    assert.are.equal(exact_options.platform, env_omitted:get("platform"))

    exact_options.environment = nil
    exact_options.platform = string.rep("p", 253) .. "é"

    local platform_truncated = metadata.new(exact_options)

    assert.is_true(encoded_size(platform_truncated) <= 512)
    assert.are.equal(string.rep("p", 253), platform_truncated:get("platform"))
    assert.are.equal(string.rep("a", 128), platform_truncated:get("application"):get("name"))
    assert.are.equal("lua-mongodb", platform_truncated:get("driver"):get("name"))
    assert.are.equal("0.3.0", platform_truncated:get("driver"):get("version"))
    assert.are.equal("test-os", platform_truncated:get("os"):get("type"))
  end)

  it("appends validated wrapper identities and deduplicates exact tuples", function()
    local initial = {
      name = "library",
      platform = "Library Platform",
      version = "1.2",
    }
    local cases = {
      {
        expected_platform = "Lua 5.4|Library Platform|Framework Platform",
        expected_version = "0.3.0|1.2|2.0",
        update = {
          name = "framework",
          platform = "Framework Platform",
          version = "2.0",
        },
      },
      {
        expected_platform = "Lua 5.4|Library Platform",
        expected_version = "0.3.0|1.2|2.0",
        update = { name = "framework", version = "2.0" },
      },
      {
        expected_platform = "Lua 5.4|Library Platform|Framework Platform",
        expected_version = "0.3.0|1.2",
        update = { name = "framework", platform = "Framework Platform" },
      },
      {
        expected_platform = "Lua 5.4|Library Platform",
        expected_version = "0.3.0|1.2",
        update = { name = "framework" },
      },
    }

    for _, test_case in ipairs(cases) do
      local value = metadata.new({
        driver_infos = { initial, test_case.update },
        platform = "Lua 5.4",
      })

      assert.are.equal(
        "lua-mongodb|library|framework",
        value:get("driver"):get("name")
      )
      assert.are.equal(
        test_case.expected_version,
        value:get("driver"):get("version")
      )
      assert.are.equal(test_case.expected_platform, value:get("platform"))
    end

    local infos = {}
    local added

    infos, added = metadata.append_driver_info(infos, {
      name = "library",
      platform = "Library Platform",
    })
    assert.is_true(added)
    infos, added = metadata.append_driver_info(infos, {
      name = "framework",
      platform = "Framework Platform",
      version = "2.0",
    })
    assert.is_true(added)
    infos, added = metadata.append_driver_info(infos, {
      name = "library",
      platform = "Library Platform",
      version = "",
    })
    assert.is_false(added)
    infos, added = metadata.append_driver_info(infos, {
      name = "Framework",
      platform = "Framework Platform",
      version = "2.0",
    })
    assert.is_true(added)
    assert.are.equal(3, #infos)

    local duplicate_cases = {
      {
        duplicate = initial,
        expected_added = false,
        original = initial,
      },
      {
        duplicate = {
          name = "library",
          platform = "Library Platform",
          version = "2.0",
        },
        expected_added = true,
        original = initial,
      },
      {
        duplicate = {
          name = "library",
          platform = "Framework Platform",
          version = "1.2",
        },
        expected_added = true,
        original = initial,
      },
      {
        duplicate = {
          name = "framework",
          platform = "Library Platform",
          version = "1.2",
        },
        expected_added = true,
        original = initial,
      },
      {
        duplicate = {
          name = "library",
          platform = "Library Platform",
          version = "",
        },
        expected_added = false,
        original = { name = "library", platform = "Library Platform" },
      },
      {
        duplicate = {
          name = "library",
          platform = "",
          version = "1.2",
        },
        expected_added = false,
        original = { name = "library", version = "1.2" },
      },
    }

    for index, test_case in ipairs(duplicate_cases) do
      local _, was_added = metadata.append_driver_info(
        { test_case.original },
        test_case.duplicate
      )

      assert.are.equal(test_case.expected_added, was_added, "case " .. index)
    end

    for _, field in ipairs({ "name", "platform", "version" }) do
      assert.has_error(function()
        metadata.normalize_driver_info({
          name = field == "name" and "bad|value" or "library",
          platform = field == "platform" and "bad|value" or nil,
          version = field == "version" and "bad|value" or nil,
        })
      end, "driver_info fields cannot contain '|'")
    end

    assert.has_error(function()
      metadata.normalize_driver_info({ name = "" })
    end, "driver_info.name must be a non-empty string")

    local bounded = metadata.new({
      app_name = string.rep("a", 128),
      driver_infos = {
        {
          name = string.rep("n", 512),
          platform = string.rep("p", 512),
          version = string.rep("v", 512),
        },
      },
      os = { type = "test-os" },
      platform = "Lua 5.4",
    })

    assert.is_true(encoded_size(bounded) <= 512)
    assert.are.equal(
      "lua-mongodb",
      bounded:get("driver"):get("name"):sub(1, #"lua-mongodb")
    )
    assert.are.equal(
      "0.3.0",
      bounded:get("driver"):get("version"):sub(1, #"0.3.0")
    )
    assert.are.equal(string.rep("a", 128), bounded:get("application"):get("name"))
    assert.are.equal("test-os", bounded:get("os"):get("type"))
  end)
end)
