local aws_credentials = require("mongodb.auth.aws_credentials")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")

describe("MONGODB-AWS credential resolution", function()
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
end)
