local fake_runtime = require("mongodb.runtime.fake")
local errors = require("mongodb.error")
local runtime = require("mongodb.runtime")
local runtime_gssapi = require("mongodb.runtime.gssapi")

describe("GSSAPI runtime provider", function()
  it("discovers binding capabilities and adapts context operations", function()
    local binding_context = {
      close = function()
        return true
      end,
      security_layer = function(_, challenge, username)
        assert.are.equal("server-layer", challenge)
        assert.are.equal("user@EXAMPLE.COM", username)
        return "client-layer"
      end,
      step = function(_, challenge)
        assert.are.equal("server-token", challenge)
        return { complete = true, token = "client-token" }
      end,
    }
    local provider = assert(runtime_gssapi.load(fake_runtime.new(), function(name)
      assert.are.equal("mongodb.runtime._gssapi", name)

      return {
        capabilities = function()
          return {
            default_credentials = true,
            password_credentials = false,
            platform = "macos",
          }
        end,
        create_context = function(options)
          assert.are.same({
            service_principal = "mongodb@db.example.com",
            username = "user@EXAMPLE.COM",
          }, options)

          return binding_context
        end,
      }
    end))

    assert.are.same({
      default_credentials = true,
      password_credentials = false,
      platform = "macos",
    }, provider:capabilities())

    local context = assert(provider:create_context({
      service_principal = "mongodb@db.example.com",
      username = "user@EXAMPLE.COM",
    }))

    assert.are.same(
      { complete = true, token = "client-token" },
      assert(context:step("server-token"))
    )
    assert.are.equal(
      "client-layer",
      assert(context:security_layer("server-layer", "user@EXAMPLE.COM"))
    )
    assert.is_true(context:close())
    assert.is_true(context:close())
  end)

  it("omits missing, unavailable, malformed, and unsupported bindings", function()
    local adapter = fake_runtime.new()

    assert.is_nil(runtime_gssapi.load(adapter, function()
      error("module not found")
    end))
    assert.is_nil(runtime_gssapi.load(adapter, function()
      return {
        capabilities = function()
          return {
            available = false,
            default_credentials = false,
            password_credentials = false,
            platform = "linux",
          }
        end,
        create_context = function() end,
      }
    end))
    assert.is_nil(runtime_gssapi.load(adapter, function()
      return { capabilities = function() return {} end }
    end))
    assert.is_nil(runtime_gssapi.load(adapter, function()
      return {
        capabilities = function()
          return {
            default_credentials = true,
            password_credentials = true,
            platform = "windows",
          }
        end,
        create_context = function() end,
      }
    end))
  end)

  it("enforces the binding's credential capabilities", function()
    local create_count = 0
    local adapter = fake_runtime.new()
    local function provider(default_credentials, password_credentials)
      return assert(runtime_gssapi.new(adapter, {
        capabilities = function()
          return {
            default_credentials = default_credentials,
            password_credentials = password_credentials,
            platform = "linux",
          }
        end,
        create_context = function()
          create_count = create_count + 1
          return {}
        end,
      }))
    end
    local context, err = provider(false, true):create_context({
      service_principal = "mongodb@db.example.com",
      username = "user@EXAMPLE.COM",
    })

    assert.is_nil(context)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal("GSSAPI_DEFAULT_CREDENTIALS_UNAVAILABLE", err.code_name)

    context, err = provider(true, false):create_context({
      password = "secret",
      service_principal = "mongodb@db.example.com",
      username = "user@EXAMPLE.COM",
    })

    assert.is_nil(context)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal("GSSAPI_PASSWORD_CREDENTIALS_UNSUPPORTED", err.code_name)
    assert.are.equal(0, create_count)
  end)

  it("checks control state around native context creation and cleans up", function()
    local adapter = fake_runtime.new()
    local closed = 0
    local provider = assert(runtime_gssapi.new(adapter, {
      capabilities = function()
        return {
          default_credentials = true,
          password_credentials = true,
          platform = "linux",
        }
      end,
      create_context = function()
        adapter:advance(2)

        return {
          close = function()
            closed = closed + 1
            return true
          end,
          security_layer = function() return "token" end,
          step = function() return { complete = false, token = "token" } end,
        }
      end,
    }))
    local context, err = provider:create_context({
      service_principal = "mongodb@db.example.com",
      username = "user@EXAMPLE.COM",
    }, 1)

    assert.is_nil(context)
    assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))
    assert.are.equal(1, closed)

    local cancellation = adapter.cancellation:new()

    cancellation:cancel("stopped")
    context, err = provider:create_context({
      service_principal = "mongodb@db.example.com",
      username = "user@EXAMPLE.COM",
    }, nil, cancellation)

    assert.is_nil(context)
    assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))
    assert.are.equal(1, closed)
  end)

  it("keeps binding diagnostics out of operational errors", function()
    local provider = assert(runtime_gssapi.new(fake_runtime.new(), {
      capabilities = function()
        return {
          default_credentials = true,
          password_credentials = true,
          platform = "macos",
        }
      end,
      create_context = function()
        error("user@EXAMPLE.COM secret")
      end,
    }))
    local context, err = provider:create_context({
      password = "secret",
      service_principal = "mongodb@db.example.com",
      username = "user@EXAMPLE.COM",
    })

    assert.is_nil(context)
    assert.are.equal("GSSAPI context creation failed", err.message)
    assert.is_nil(err.message:find("secret", 1, true))
    assert.is_nil(err.message:find("user@EXAMPLE.COM", 1, true))
  end)

  it("preserves a complete custom provider override", function()
    local custom = { create_context = function() end }
    local adapter = runtime.copas({ gssapi = custom })

    assert.are.equal(custom, adapter.gssapi)
  end)
end)
