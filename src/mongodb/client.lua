local api = require("mongodb.api")
local bson = require("mongodb.bson")
local command_executor = require("mongodb.command.executor")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")
local monitoring = require("mongodb.monitoring")
local runtime_contract = require("mongodb.runtime")
local scram = require("mongodb.auth.scram")
local transport = require("mongodb.network.transport")
local uri_parser = require("mongodb.config.uri")

local M = {}

local SPECIAL_OPTIONS = {
  cancellation = true,
  command_listeners = true,
  deadline = true,
  on_listener_error = true,
  runtime = true,
}

local function configuration_error(message)
  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    message = message,
  })
end

local function split_options(values)
  if values == nil then
    return {}, {}
  end

  if type(values) ~= "table" then
    error("client options must be a table", 3)
  end

  local special = {}
  local programmatic = {}

  for key, value in pairs(values) do
    if SPECIAL_OPTIONS[key] then
      special[key] = value
    else
      programmatic[key] = value
    end
  end

  return programmatic, special
end

local function address(host)
  local port = host.port or 27017

  if host.type == "ip_literal" then
    return "[" .. host.host .. "]:" .. port
  end

  return host.host .. ":" .. port
end

local function tls_options(config, host)
  if not config.tls then
    return nil
  end

  return {
    allow_invalid_certificates = config.tls_allow_invalid_certificates,
    allow_invalid_hostnames = config.tls_allow_invalid_hostnames,
    ca_file = config.tls_ca_file,
    certificate_key_file = config.tls_certificate_key_file,
    certificate_key_file_password = config.tls_certificate_key_file_password,
    disable_certificate_revocation_check = config.tls_disable_certificate_revocation_check,
    disable_ocsp_endpoint_check = config.tls_disable_ocsp_endpoint_check,
    insecure = config.tls_insecure,
    server_name = host.host,
  }
end

local function combine_warnings(parsed, normalized)
  local result = {}

  for _, source in ipairs({ parsed.warnings or {}, normalized or {} }) do
    for index = 1, #source do
      result[#result + 1] = source[index]
    end
  end

  return result
end

local function mechanism_from(hello, configured)
  if configured ~= nil then
    if configured ~= "SCRAM-SHA-1" and configured ~= "SCRAM-SHA-256" then
      return configuration_error("only SCRAM-SHA-1 and SCRAM-SHA-256 are supported")
    end

    return configured
  end

  local supported = hello.document:get("saslSupportedMechs")

  if bson.is_array(supported) then
    for _, mechanism in supported:iter() do
      if mechanism == "SCRAM-SHA-256" then
        return mechanism
      end
    end
  end

  return "SCRAM-SHA-1"
end

function M.connect(uri, values)
  local parsed, err = uri_parser.parse(uri)

  if not parsed then
    return nil, err
  end

  if #parsed.hosts ~= 1 then
    return configuration_error("the standalone client requires exactly one seed")
  end

  local host = parsed.hosts[1]

  if host.type == "unix" then
    return configuration_error("Unix domain sockets are not supported by the current runtime")
  end

  local programmatic, special = split_options(values)
  local config, config_err, option_warnings = driver_options.normalize(
    parsed.options,
    programmatic
  )

  if not config then
    return nil, config_err
  end

  local runtime = special.runtime or runtime_contract.copas()

  runtime_contract.validate(runtime)
  local deadline = special.deadline

  if deadline == nil and config.connect_timeout_ms > 0 then
    deadline = runtime_contract.deadline_after(runtime, config.connect_timeout_ms / 1000)
  end

  local monitor = monitoring.new({
    clock = runtime.clock,
    listeners = special.command_listeners or {},
    on_listener_error = special.on_listener_error,
  })
  local connection
  connection, err = transport.connect(runtime, host.host, host.port or 27017, {
    cancellation = special.cancellation,
    deadline = deadline,
    tls = tls_options(config, host),
  })

  if not connection then
    return nil, err
  end

  local executor = command_executor.new(connection, {
    app_name = config.app_name,
    monitoring = monitor,
    server = address(host),
    server_api = config.server_api,
  })
  local auth_source = config.auth_source or parsed.database or "admin"
  local hello_options = {
    cancellation = special.cancellation,
    deadline = deadline,
  }

  if parsed.username ~= nil then
    hello_options.sasl_supported_mechs = auth_source .. "." .. parsed.username
  end

  local hello
  hello, err = executor:hello(hello_options)

  if not hello then
    executor:close()
    return nil, err
  end

  if hello.server_type ~= "standalone" then
    executor:close()
    return configuration_error("the standalone client cannot use this server topology")
  end

  if parsed.username ~= nil then
    local mechanism
    mechanism, err = mechanism_from(hello, config.auth_mechanism)

    if not mechanism then
      executor:close()
      return nil, err
    end

    local authenticated
    authenticated, err = scram.authenticate(executor, runtime, {
      mechanism = mechanism,
      password = parsed.password or "",
      source = auth_source,
      username = parsed.username,
    }, {
      cancellation = special.cancellation,
      deadline = deadline,
    })

    if not authenticated then
      executor:close()
      return nil, err
    end
  end

  return api.new_client(
    executor,
    config,
    parsed.database,
    combine_warnings(parsed, option_warnings)
  )
end

return M
