local errors = require("mongodb.error")

local M = {}

local ALLOWED_CONSTRUCTOR_OPTIONS = {
  default_ca_file = true,
  default_ca_path = true,
  socket_adapter = true,
  ssl = true,
}
local ALLOWED_WRAP_OPTIONS = {
  allow_invalid_certificates = true,
  allow_invalid_hostnames = true,
  ca_file = true,
  certificate_key_file = true,
  certificate_key_file_password = true,
  disable_certificate_revocation_check = true,
  disable_ocsp_endpoint_check = true,
  insecure = true,
  server_name = true,
}
local DEFAULT_CA_FILES = {
  "/etc/ssl/cert.pem",
  "/etc/ssl/certs/ca-certificates.crt",
  "/etc/pki/tls/certs/ca-bundle.crt",
  "/etc/ssl/ca-bundle.pem",
}

local function configuration_error(message)
  return errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    message = message,
  })
end

local function readable(path)
  if type(path) ~= "string" or path == "" then
    return false
  end

  local file = io.open(path, "rb")

  if not file then
    return false
  end

  file:close()
  return true
end

local function default_ca_file()
  local environment = os.getenv("SSL_CERT_FILE")

  if readable(environment) then
    return environment
  end

  for _, path in ipairs(DEFAULT_CA_FILES) do
    if readable(path) then
      return path
    end
  end
end

local function validate_constructor_options(options)
  if type(options) ~= "table" then
    error("LuaSec adapter options must be a table", 3)
  end

  for key in pairs(options) do
    if not ALLOWED_CONSTRUCTOR_OPTIONS[key] then
      error("unknown LuaSec adapter option: " .. tostring(key), 3)
    end
  end

  for _, name in ipairs({ "default_ca_file", "default_ca_path" }) do
    local value = options[name]

    if value ~= nil and (type(value) ~= "string" or value == "") then
      error(name .. " must be a non-empty string when provided", 3)
    end
  end

  if options.socket_adapter ~= nil
      and (type(options.socket_adapter) ~= "table"
        or type(options.socket_adapter.wrap_tls) ~= "function")
  then
    error("socket_adapter must provide wrap_tls", 3)
  end

  if options.ssl ~= nil
      and (type(options.ssl) ~= "table" or type(options.ssl.newcontext) ~= "function")
  then
    error("ssl must provide newcontext", 3)
  end
end

local function validate_wrap_options(options)
  if type(options) ~= "table" then
    error("TLS options must be a table", 3)
  end

  for key in pairs(options) do
    if not ALLOWED_WRAP_OPTIONS[key] then
      error("unknown TLS option: " .. tostring(key), 3)
    end
  end

  if type(options.server_name) ~= "string" or options.server_name == "" then
    error("TLS server_name must be a non-empty string", 3)
  end

  for _, name in ipairs({ "allow_invalid_certificates", "allow_invalid_hostnames",
      "disable_certificate_revocation_check", "disable_ocsp_endpoint_check", "insecure" })
  do
    if options[name] ~= nil and type(options[name]) ~= "boolean" then
      error(name .. " must be a boolean when provided", 3)
    end
  end

  for _, name in ipairs({ "ca_file", "certificate_key_file" }) do
    if options[name] ~= nil and (type(options[name]) ~= "string" or options[name] == "") then
      error(name .. " must be a non-empty string when provided", 3)
    end
  end

  if options.certificate_key_file_password ~= nil
      and type(options.certificate_key_file_password) ~= "string"
  then
    error("certificate_key_file_password must be a string when provided", 3)
  end

  if options.certificate_key_file_password ~= nil and options.certificate_key_file == nil then
    return nil, configuration_error(
      "TLS certificate key password requires a certificate key file"
    )
  end

  return true
end

local function context_parameters(options, defaults)
  local insecure = options.insecure == true
  local allow_invalid_certificates = insecure or options.allow_invalid_certificates == true
  local allow_invalid_hostnames = insecure or allow_invalid_certificates
    or options.allow_invalid_hostnames == true
  local parameters = {
    mode = "client",
    options = { "all", "no_sslv2", "no_sslv3", "no_compression", "no_renegotiation" },
    protocol = "any",
    verify = allow_invalid_certificates
      and "none"
      or { "peer", "fail_if_no_peer_cert" },
  }

  if not allow_invalid_certificates then
    parameters.cafile = options.ca_file or defaults.ca_file
    parameters.capath = parameters.cafile == nil and defaults.ca_path or nil

    if parameters.cafile == nil and parameters.capath == nil then
      return nil, configuration_error("no TLS certificate authority store is available")
    end
  end

  if options.certificate_key_file then
    parameters.certificate = options.certificate_key_file
    parameters.key = options.certificate_key_file
    parameters.password = options.certificate_key_file_password
  end

  return parameters, not allow_invalid_hostnames
end

function M.new(runtime, options)
  if type(runtime) ~= "table" then
    error("LuaSec adapter requires its owning runtime", 2)
  end

  options = options or {}
  validate_constructor_options(options)

  local socket_adapter = options.socket_adapter or require("mongodb.runtime.copas_socket")
  local ssl = options.ssl or require("ssl")
  local defaults = {
    ca_file = options.default_ca_file or default_ca_file(),
    ca_path = options.default_ca_path or os.getenv("SSL_CERT_DIR"),
  }

  if defaults.ca_path == "" then
    defaults.ca_path = nil
  end
  local provider = {}

  function provider.wrap(_, socket, wrap_options, deadline, token)
    local valid, err = validate_wrap_options(wrap_options)

    if not valid then
      return nil, err
    end

    local parameters, check_hostname = context_parameters(wrap_options, defaults)

    if not parameters then
      return nil, check_hostname
    end

    local context_outcome = table.pack(pcall(ssl.newcontext, parameters))

    if not context_outcome[1] or context_outcome[2] == nil then
      return nil, configuration_error("TLS context configuration failed")
    end

    return socket_adapter.wrap_tls(
      socket,
      context_outcome[2],
      wrap_options.server_name,
      check_hostname,
      deadline,
      token
    )
  end

  return provider
end

return M
