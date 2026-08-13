local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")
local uri_parser = require("mongodb.config.uri")

local M = {}

local ALLOWED_TXT_OPTIONS = {
  authsource = "auth_source",
  loadbalanced = "load_balanced",
  replicaset = "replica_set",
}

local function configuration_error(message, cause, details)
  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    cause = cause,
    details = details,
    message = message,
  })
end

local function split_labels(hostname)
  local labels = {}

  for label in hostname:gmatch("[^.]+") do
    labels[#labels + 1] = label
  end

  return labels
end

local function source_domain(hostname)
  local labels = split_labels(hostname)

  if #labels < 3 then
    return hostname
  end

  return table.concat(labels, ".", 2)
end

local function normalize_target(source, record)
  if type(record) ~= "table" then
    return configuration_error("SRV lookup returned a malformed record")
  end

  local target = record.target

  if type(target) ~= "string" or target == "" then
    return configuration_error("SRV lookup returned an invalid hostname")
  end

  target = target:lower():gsub("%.$", "")

  if target == "" or target:find("/", 1, true) or target:find(":", 1, true) then
    return configuration_error("SRV lookup returned an invalid hostname")
  end

  if math.type(record.port) ~= "integer" or record.port < 1 or record.port > 65535 then
    return configuration_error("SRV lookup returned an invalid port")
  end

  if math.type(record.ttl) ~= "integer" or record.ttl < 0 then
    return configuration_error("SRV lookup returned an invalid TTL")
  end

  local domain = source_domain(source)
  local suffix = "." .. domain

  if #target <= #suffix or target:sub(-#suffix) ~= suffix then
    return configuration_error(
      "SRV lookup returned a hostname outside the URI domain",
      nil,
      { hostname = target }
    )
  end

  return {
    host = target,
    port = record.port,
    ttl = record.ttl,
    type = "hostname",
  }
end

local function random_index(runtime, maximum, provided)
  if provided ~= nil then
    local index = provided(maximum)

    if math.type(index) ~= "integer" or index < 1 or index > maximum then
      error("DNS random selector returned an out-of-range index", 3)
    end

    return index
  end

  local range = 0x100000000
  local limit = range - range % maximum

  while true do
    local bytes, err = runtime.entropy:bytes(4)

    if bytes == nil then
      return nil, err
    end

    if #bytes ~= 4 then
      error("runtime entropy adapter returned an invalid DNS sample", 0)
    end

    local sample = string.unpack(">I4", bytes)

    if sample < limit then
      return sample % maximum + 1
    end
  end
end

local function select_hosts(hosts, maximum, runtime, random)
  if maximum == nil or maximum == 0 or maximum >= #hosts then
    return hosts
  end

  local shuffled = {}

  for index, host in ipairs(hosts) do
    shuffled[index] = host
  end

  for index = #shuffled, 2, -1 do
    local selected, err = random_index(runtime, index, random)

    if selected == nil then
      return nil, err
    end

    shuffled[index], shuffled[selected] = shuffled[selected], shuffled[index]
  end

  local result = {}

  for index = 1, maximum do
    result[index] = shuffled[index]
  end

  return result
end

local function host_address(host)
  return host.host .. ":" .. tostring(host.port)
end

local function explicit_option_names(parsed, programmatic)
  local names = {}

  for _, pair in ipairs(parsed.options) do
    local normalized = ALLOWED_TXT_OPTIONS[pair.key]

    if normalized ~= nil then
      names[normalized] = true
    end
  end

  for name in pairs(programmatic) do
    if name == "auth_source" or name == "replica_set" or name == "load_balanced" then
      names[name] = true
    end
  end

  return names
end

local function txt_options(records, parsed, programmatic)
  if type(records) ~= "table" then
    return configuration_error("TXT lookup returned a malformed result")
  end

  if #records > 1 then
    return configuration_error("DNS seedlist discovery supports only one TXT record")
  end

  if #records == 0 then
    return {}
  end

  local record = records[1]

  if type(record) ~= "table" or type(record.strings) ~= "table" then
    return configuration_error("TXT lookup returned a malformed record")
  end

  local chunks = {}

  for index, value in ipairs(record.strings) do
    if type(value) ~= "string" then
      return configuration_error("TXT lookup returned a malformed character string")
    end

    chunks[index] = value
  end

  local options, err = uri_parser.parse_options(table.concat(chunks))

  if options == nil then
    return nil, err
  end

  local explicit = explicit_option_names(parsed, programmatic)
  local defaults = {}

  for _, pair in ipairs(options) do
    local normalized = ALLOWED_TXT_OPTIONS[pair.key]

    if normalized == nil then
      return configuration_error(
        "TXT records may contain only authSource, replicaSet, or loadBalanced"
      )
    end

    if not explicit[normalized] then
      defaults[#defaults + 1] = pair
    end
  end

  return defaults
end

local function copy_parsed(parsed, hosts, service_name, minimum_ttl)
  local result = {}

  for key, value in pairs(parsed) do
    result[key] = value
  end

  result.hosts = hosts
  result.srv = {
    hostname = parsed.hosts[1].host,
    minimum_ttl = minimum_ttl,
    service_name = service_name,
  }
  return result
end

function M.resolve(parsed, programmatic, runtime, fields)
  if type(parsed) ~= "table" or not parsed.is_srv then
    error("initial DNS discovery requires a parsed mongodb+srv URI", 2)
  end

  if type(programmatic) ~= "table" then
    error("initial DNS discovery requires programmatic options", 2)
  end

  fields = fields or {}

  local preliminary, err = driver_options.normalize(
    parsed.options,
    programmatic,
    parsed
  )

  if preliminary == nil then
    return nil, err
  end

  local hostname = parsed.hosts[1].host
  local service_name = preliminary.srv_service_name or "mongodb"
  local query_name = "_" .. service_name .. "._tcp." .. hostname
  local srv_records
  srv_records, err = runtime.dns:resolve_srv(
    query_name,
    fields.deadline,
    fields.cancellation
  )

  if srv_records == nil then
    return configuration_error("SRV lookup failed: " .. err.message, err)
  end

  if #srv_records == 0 then
    return configuration_error("SRV lookup returned no records")
  end

  local hosts = {}
  local seen = {}
  local minimum_ttl

  for _, record in ipairs(srv_records) do
    local host
    host, err = normalize_target(hostname, record)

    if host == nil then
      return nil, err
    end

    minimum_ttl = math.min(minimum_ttl or host.ttl, host.ttl)
    local identity = host.host .. ":" .. tostring(host.port)

    if not seen[identity] then
      seen[identity] = true
      hosts[#hosts + 1] = {
        host = host.host,
        port = host.port,
        type = host.type,
      }
    end
  end

  hosts, err = select_hosts(
    hosts,
    preliminary.srv_max_hosts,
    runtime,
    fields.random
  )

  if hosts == nil then
    return nil, err
  end

  local txt_records
  txt_records, err = runtime.dns:resolve_txt(
    hostname,
    fields.deadline,
    fields.cancellation
  )

  if txt_records == nil then
    return configuration_error("TXT lookup failed: " .. err.message, err)
  end

  local defaults
  defaults, err = txt_options(txt_records, parsed, programmatic)

  if defaults == nil then
    return nil, err
  end

  local combined = {}

  for _, source in ipairs({ defaults, parsed.options }) do
    for _, pair in ipairs(source) do
      combined[#combined + 1] = pair
    end
  end

  local resolved = copy_parsed(parsed, hosts, service_name, minimum_ttl)
  local config, config_err, warnings = driver_options.normalize(
    combined,
    programmatic,
    resolved
  )

  if config == nil then
    return nil, config_err
  end

  local valid
  valid, err = driver_options.validate_uri(resolved, config)

  if not valid then
    return nil, err
  end

  return resolved, config, warnings
end

function M.poll(srv, runtime, fields)
  if type(srv) ~= "table" or type(srv.hostname) ~= "string"
      or srv.hostname == "" or type(srv.service_name) ~= "string"
      or srv.service_name == ""
  then
    error("SRV polling requires seedlist discovery metadata", 2)
  end

  if math.type(srv.max_hosts) ~= "integer" or srv.max_hosts < 0 then
    error("SRV polling max_hosts must be a non-negative integer", 2)
  end

  fields = fields or {}
  local query_name = "_" .. srv.service_name .. "._tcp." .. srv.hostname
  local records, err = runtime.dns:resolve_srv(
    query_name,
    fields.deadline,
    fields.cancellation
  )

  if records == nil then
    return nil, err
  end

  if type(records) ~= "table" then
    error("runtime DNS SRV result must be an array", 2)
  end

  local valid = {}
  local seen = {}
  local minimum_ttl

  for _, record in ipairs(records) do
    local host = normalize_target(srv.hostname, record)

    if host ~= nil then
      local address = host_address(host)

      minimum_ttl = math.min(minimum_ttl or host.ttl, host.ttl)

      if not seen[address] then
        seen[address] = true
        valid[#valid + 1] = {
          host = host.host,
          port = host.port,
          type = host.type,
        }
      end
    end
  end

  if #valid == 0 then
    return { hosts = {} }
  end

  if srv.max_hosts == 0 or srv.max_hosts >= #valid then
    return { hosts = valid, minimum_ttl = minimum_ttl }
  end

  local current = {}

  for _, address in ipairs(fields.current_addresses or {}) do
    current[address:lower()] = true
  end

  local retained = {}
  local candidates = {}

  for _, host in ipairs(valid) do
    if current[host_address(host)] then
      retained[#retained + 1] = host
    else
      candidates[#candidates + 1] = host
    end
  end

  local capacity = math.max(0, srv.max_hosts - #retained)
  local selected

  if capacity == 0 then
    selected = {}
  else
    selected, err = select_hosts(candidates, capacity, runtime, fields.random)
  end

  if selected == nil then
    return nil, err
  end

  for _, host in ipairs(selected) do
    if #retained >= srv.max_hosts then
      break
    end

    retained[#retained + 1] = host
  end

  return { hosts = retained, minimum_ttl = minimum_ttl }
end

return M
