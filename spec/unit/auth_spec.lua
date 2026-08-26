local auth = require("mongodb.auth")
local bson = require("mongodb.bson")
local fake_runtime = require("mongodb.runtime.fake")

local function response(payload, done)
  return bson.document({
    { "conversationId", 9 },
    { "payload", bson.binary(payload) },
    { "done", done },
    { "ok", 1 },
  })
end

describe("authentication dispatch", function()
  it("routes GSSAPI credentials to the GSSAPI conversation", function()
    local runtime = fake_runtime.new()
    local provider_step = 0

    runtime.gssapi = {
      create_context = function()
        return {
          close = function()
            return true
          end,
          security_layer = function()
            return "client-layer"
          end,
          step = function()
            provider_step = provider_step + 1
            return {
              complete = provider_step == 2,
              token = "client-" .. provider_step,
            }
          end,
        }
      end,
    }

    local command_step = 0
    local commands = {
      command = function(_, _, body)
        command_step = command_step + 1
        assert.are.equal(command_step == 1 and "saslStart" or "saslContinue", body:keys()[1])

        if command_step == 1 then
          return response("server-one", false)
        elseif command_step == 2 then
          return response("server-layer", false)
        end

        return response("", true)
      end,
    }

    assert.is_true(auth.authenticate(commands, runtime, {
      mechanism = "GSSAPI",
      mechanism_properties = {
        CANONICALIZE_HOST_NAME = "none",
        SERVICE_NAME = "mongodb",
      },
      source = "$external",
      username = "user@REALM",
    }, {
      mechanism = "GSSAPI",
      server_host = "db.example.com",
    }))
    assert.are.equal(3, command_step)
  end)
end)
