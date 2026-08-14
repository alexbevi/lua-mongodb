local aws = require("mongodb.auth.aws")
local aws_credentials = require("mongodb.auth.aws_credentials")
local aws_ec2 = require("mongodb.auth.aws_ec2")
local aws_ecs = require("mongodb.auth.aws_ecs")
local aws_web_identity = require("mongodb.auth.aws_web_identity")
local oidc = require("mongodb.auth.oidc")
local plain = require("mongodb.auth.plain")
local scram = require("mongodb.auth.scram")
local x509 = require("mongodb.auth.x509")

local M = {}

function M.speculative_command(commands, credentials)
  if type(credentials) ~= "table" then
    error("authentication credentials must be a table", 2)
  end

  if credentials.mechanism ~= "MONGODB-OIDC" then
    return nil
  end

  return oidc.speculative_command(commands, credentials)
end

function M.authenticate(commands, runtime, credentials, options)
  if type(credentials) ~= "table" then
    error("authentication credentials must be a table", 2)
  end

  if options ~= nil and type(options) ~= "table" then
    error("authentication options must be a table", 2)
  end

  local mechanism = options and options.mechanism or credentials.mechanism

  if mechanism == "MONGODB-AWS" then
    local resolved = credentials
    local err

    if credentials.username == nil and credentials.password == nil then
      local resolve_options = options or {}

      local provider

      if resolve_options.provider == nil then
        if aws_web_identity.is_configured(runtime) then
          provider = aws_web_identity.resolve
        elseif aws_ecs.is_configured(runtime) then
          provider = aws_ecs.resolve
        else
          provider = aws_ec2.resolve
        end
      end

      if provider ~= nil then
        local with_provider = {}

        for name, value in pairs(resolve_options) do
          with_provider[name] = value
        end

        with_provider.provider = provider
        resolve_options = with_provider
      end

      resolved, err = aws_credentials.resolve(
        runtime,
        credentials,
        resolve_options
      )

      if not resolved then
        return nil, err
      end
    end

    local authenticated

    authenticated, err = aws.authenticate(commands, runtime, resolved, options)

    if not authenticated then
      aws_credentials.invalidate(resolved)
      return nil, err
    end

    return true
  end

  if mechanism == "PLAIN" then
    return plain.authenticate(commands, credentials, options)
  end

  if mechanism == "MONGODB-OIDC" then
    return oidc.authenticate(commands, runtime, credentials, options)
  end

  if mechanism == "MONGODB-X509" then
    return x509.authenticate(commands, credentials, options)
  end

  return scram.authenticate(commands, runtime, credentials, options)
end

return M
