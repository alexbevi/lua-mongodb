local aws_credentials = require("mongodb.auth.aws_credentials")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

describe("MONGODB-AWS credential resolution", function()
  before_each(function()
    aws_credentials.clear_cache()
  end)

  after_each(function()
    aws_credentials.clear_cache()
  end)

  it("resolves complete environment credentials dynamically", function()
    local runtime = fake_runtime.new({
      environment = {
        AWS_ACCESS_KEY_ID = "FIRST_ACCESS_KEY",
        AWS_SECRET_ACCESS_KEY = "FIRST_SECRET_KEY",
      },
    })
    local shell = {
      mechanism = "MONGODB-AWS",
      source = "$external",
    }
    local first = assert(aws_credentials.resolve(runtime, shell))

    assert.are.equal("FIRST_ACCESS_KEY", first.username)
    assert.are.equal("FIRST_SECRET_KEY", first.password)
    assert.is_nil(first.session_token)
    assert.has_error(function()
      first.username = "replacement"
    end, "resolved AWS credentials are immutable")

    runtime:set_environment("AWS_ACCESS_KEY_ID", "SECOND_ACCESS_KEY")
    runtime:set_environment("AWS_SECRET_ACCESS_KEY", "SECOND_SECRET_KEY")
    runtime:set_environment("AWS_SESSION_TOKEN", "SECOND_SESSION_TOKEN")

    local second = assert(aws_credentials.resolve(runtime, shell))

    assert.are.equal("SECOND_ACCESS_KEY", second.username)
    assert.are.equal("SECOND_SECRET_KEY", second.password)
    assert.are.equal("SECOND_SESSION_TOKEN", second.session_token)
    assert.is_nil(shell.username)
    assert.is_nil(shell.password)
    assert.are.same({
      "AWS_ACCESS_KEY_ID",
      "AWS_SECRET_ACCESS_KEY",
      "AWS_SESSION_TOKEN",
      "AWS_ACCESS_KEY_ID",
      "AWS_SECRET_ACCESS_KEY",
      "AWS_SESSION_TOKEN",
    }, runtime.calls.environment)
  end)

  it("rejects absent and incomplete environment credentials without values", function()
    local cases = {
      {},
      { AWS_ACCESS_KEY_ID = "PRIVATE_ACCESS" },
      { AWS_SECRET_ACCESS_KEY = "PRIVATE_SECRET" },
      { AWS_SESSION_TOKEN = "PRIVATE_TOKEN" },
      {
        AWS_ACCESS_KEY_ID = "PRIVATE_ACCESS",
        AWS_SESSION_TOKEN = "PRIVATE_TOKEN",
      },
      {
        AWS_SECRET_ACCESS_KEY = "PRIVATE_SECRET",
        AWS_SESSION_TOKEN = "PRIVATE_TOKEN",
      },
      {
        AWS_ACCESS_KEY_ID = "",
        AWS_SECRET_ACCESS_KEY = "PRIVATE_SECRET",
      },
      {
        AWS_ACCESS_KEY_ID = "PRIVATE_ACCESS",
        AWS_SECRET_ACCESS_KEY = "",
      },
      {
        AWS_ACCESS_KEY_ID = "PRIVATE_ACCESS",
        AWS_SECRET_ACCESS_KEY = "PRIVATE_SECRET",
        AWS_SESSION_TOKEN = "",
      },
    }

    for _, environment in ipairs(cases) do
      local runtime = fake_runtime.new({ environment = environment })
      local credential, err = aws_credentials.resolve(runtime, {
        mechanism = "MONGODB-AWS",
        source = "$external",
      })

      assert.is_nil(credential)
      assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
      assert.is_nil(tostring(err):find("PRIVATE_ACCESS", 1, true))
      assert.is_nil(tostring(err):find("PRIVATE_SECRET", 1, true))
      assert.is_nil(tostring(err):find("PRIVATE_TOKEN", 1, true))
    end
  end)

  it("reuses provider credentials until expiration is within one minute", function()
    local runtime = fake_runtime.new({ wall_time = 1000 })
    local calls = 0
    local provider = function()
      calls = calls + 1
      return {
        expiration = runtime.clock:wall_time() + 120,
        password = "SECRET_" .. calls,
        session_token = "TOKEN_" .. calls,
        username = "ACCESS_" .. calls,
      }
    end
    local shell = {
      mechanism = "MONGODB-AWS",
      source = "$external",
    }
    local first = assert(aws_credentials.resolve(runtime, shell, {
      provider = provider,
    }))
    local reused = assert(aws_credentials.resolve(runtime, shell, {
      provider = provider,
    }))

    assert.are.equal("ACCESS_1", first.username)
    assert.are.equal("ACCESS_1", reused.username)
    assert.are.equal(1, calls)

    runtime:advance(60)

    local refreshed = assert(aws_credentials.resolve(runtime, shell, {
      provider = provider,
    }))

    assert.are.equal("ACCESS_2", refreshed.username)
    assert.are.equal(2, calls)
  end)

  it("orders environment and cached provider credentials normatively", function()
    local runtime = fake_runtime.new({
      environment = {
        AWS_ACCESS_KEY_ID = "ENV_ACCESS",
        AWS_SECRET_ACCESS_KEY = "ENV_SECRET",
      },
      wall_time = 1000,
    })
    local calls = 0
    local provider = function()
      calls = calls + 1
      return {
        expiration = 2000,
        password = "PROVIDER_SECRET",
        session_token = "PROVIDER_TOKEN",
        username = "PROVIDER_ACCESS",
      }
    end
    local shell = {
      mechanism = "MONGODB-AWS",
      source = "$external",
    }
    local environment = assert(aws_credentials.resolve(runtime, shell, {
      provider = provider,
    }))

    assert.are.equal("ENV_ACCESS", environment.username)
    assert.are.equal(0, calls)

    runtime:set_environment("AWS_ACCESS_KEY_ID", nil)
    runtime:set_environment("AWS_SECRET_ACCESS_KEY", nil)

    local provider_credential = assert(aws_credentials.resolve(runtime, shell, {
      provider = provider,
    }))

    assert.are.equal("PROVIDER_ACCESS", provider_credential.username)
    assert.are.equal(1, calls)

    runtime:set_environment("AWS_ACCESS_KEY_ID", "LATER_ENV_ACCESS")
    runtime:set_environment("AWS_SECRET_ACCESS_KEY", "LATER_ENV_SECRET")

    local cached = assert(aws_credentials.resolve(runtime, {
      mechanism = "MONGODB-AWS",
      source = "$external",
    }, { provider = provider }))

    assert.are.equal("PROVIDER_ACCESS", cached.username)
    assert.are.equal(1, calls)

    aws_credentials.clear_cache()

    local later_environment = assert(aws_credentials.resolve(runtime, shell, {
      provider = provider,
    }))

    assert.are.equal("LATER_ENV_ACCESS", later_environment.username)
    assert.are.equal(1, calls)
  end)

  it("rejects expired and malformed provider credentials without values", function()
    local runtime = fake_runtime.new({ wall_time = 1000 })
    local shell = {
      mechanism = "MONGODB-AWS",
      source = "$external",
    }
    local providers = {
      function()
        return {
          expiration = 1000,
          password = "PRIVATE_SECRET",
          session_token = "PRIVATE_TOKEN",
          username = "PRIVATE_ACCESS",
        }
      end,
      function()
        return {
          expiration = 2000,
          password = "PRIVATE_SECRET",
          username = "",
        }
      end,
      function()
        return nil, errors.new({
          category = errors.CATEGORY.NETWORK,
          message = "PRIVATE_SECRET PRIVATE_TOKEN",
        })
      end,
    }

    for _, provider in ipairs(providers) do
      local credential, err = aws_credentials.resolve(runtime, shell, {
        provider = provider,
      })

      assert.is_nil(credential)
      assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
      assert.is_nil(tostring(err):find("PRIVATE_ACCESS", 1, true))
      assert.is_nil(tostring(err):find("PRIVATE_SECRET", 1, true))
      assert.is_nil(tostring(err):find("PRIVATE_TOKEN", 1, true))
      aws_credentials.clear_cache()
    end
  end)
end)
