local errors = require("mongodb.error")

local M = {}

local function invalid_provider_result()
  return nil, errors.new({
    category = errors.CATEGORY.INTERNAL,
    details = { operation = "gssapi_dns" },
    message = "runtime GSSAPI DNS provider returned an invalid result",
  })
end

local function control_error(err)
  return errors.is(err, errors.CATEGORY.CANCELLED)
    or errors.is(err, errors.CATEGORY.TIMEOUT)
end

local function forward_host(runtime, host, deadline, cancellation)
  local dns = runtime.dns

  if type(dns) ~= "table" or type(dns.resolve_host) ~= "function" then
    return host
  end

  local result, err = dns:resolve_host(host, deadline, cancellation)

  if not result then
    if control_error(err) then
      return nil, err
    end

    return host
  end

  if type(result) ~= "table"
      or type(result.address) ~= "string" or result.address == ""
      or type(result.canonical_name) ~= "string" or result.canonical_name == ""
  then
    return invalid_provider_result()
  end

  return result.canonical_name:lower(), nil, result.address
end

local function reverse_host(runtime, host, address, deadline, cancellation)
  local dns = runtime.dns

  if type(dns) ~= "table" or type(dns.resolve_address) ~= "function" then
    return host
  end

  local result, err = dns:resolve_address(address, deadline, cancellation)

  if not result then
    if control_error(err) then
      return nil, err
    end

    return host
  elseif type(result) ~= "string" or result == "" then
    return invalid_provider_result()
  end

  return result:lower()
end

function M.service_host(runtime, credential, server_host, deadline, cancellation)
  if type(runtime) ~= "table" or type(credential) ~= "table"
      or type(server_host) ~= "string" or server_host == "" then
    error("GSSAPI service-host resolution requires runtime, credential, and host", 2)
  end

  local properties = credential.mechanism_properties or {}
  local host = properties.SERVICE_HOST or server_host
  local mode = properties.CANONICALIZE_HOST_NAME or "none"

  if mode == "none" then
    return host
  elseif mode ~= "forward" and mode ~= "forwardAndReverse" then
    error("normalized GSSAPI hostname canonicalization mode is invalid", 2)
  end

  local canonical, err, address = forward_host(
    runtime, host, deadline, cancellation
  )

  if not canonical or mode == "forward" or address == nil then
    return canonical, err
  end

  return reverse_host(runtime, host, address, deadline, cancellation)
end

return M
