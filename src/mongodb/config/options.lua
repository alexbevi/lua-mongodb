local errors = require("mongodb.error")

local M = {}

local URI_NAMES = {
  appname = "app_name",
  authmechanism = "auth_mechanism",
  authmechanismproperties = "auth_mechanism_properties",
  authsource = "auth_source",
  connecttimeoutms = "connect_timeout_ms",
  directconnection = "direct_connection",
  heartbeatfrequencyms = "heartbeat_frequency_ms",
  journal = "journal",
  loadbalanced = "load_balanced",
  localthresholdms = "local_threshold_ms",
  maxconnecting = "max_connecting",
  maxidletimems = "max_idle_time_ms",
  maxpoolsize = "max_pool_size",
  maxstalenessseconds = "max_staleness_seconds",
  minpoolsize = "min_pool_size",
  readconcernlevel = "read_concern_level",
  readpreference = "read_preference_mode",
  readpreferencetags = "read_preference_tags",
  replicaset = "replica_set",
  retryreads = "retry_reads",
  retrywrites = "retry_writes",
  servermonitoringmode = "server_monitoring_mode",
  serverselectiontimeoutms = "server_selection_timeout_ms",
  serverselectiontryonce = "server_selection_try_once",
  sockettimeoutms = "socket_timeout_ms",
  srvmaxhosts = "srv_max_hosts",
  srvservicename = "srv_service_name",
  ssl = "tls",
  timeoutms = "timeout_ms",
  tls = "tls",
  tlsallowinvalidcertificates = "tls_allow_invalid_certificates",
  tlsallowinvalidhostnames = "tls_allow_invalid_hostnames",
  tlscafile = "tls_ca_file",
  tlscertificatekeyfile = "tls_certificate_key_file",
  tlscertificatekeyfilepassword = "tls_certificate_key_file_password",
  tlsdisablecertificaterevocationcheck = "tls_disable_certificate_revocation_check",
  tlsdisableocspendpointcheck = "tls_disable_ocsp_endpoint_check",
  tlsinsecure = "tls_insecure",
  w = "w",
  waitqueuetimeoutms = "wait_queue_timeout_ms",
  wtimeout = "w_timeout_ms",
  wtimeoutms = "w_timeout_ms",
}

local PROGRAMMATIC_NAMES = {
  app_name = true,
  auth_mechanism = true,
  auth_mechanism_properties = true,
  auth_source = true,
  connect_timeout_ms = true,
  direct_connection = true,
  heartbeat_frequency_ms = true,
  local_threshold_ms = true,
  load_balanced = true,
  max_connecting = true,
  max_idle_time_ms = true,
  max_pool_size = true,
  min_pool_size = true,
  replica_set = true,
  retry_reads = true,
  retry_writes = true,
  server_monitoring_mode = true,
  server_selection_timeout_ms = true,
  server_selection_try_once = true,
  socket_timeout_ms = true,
  srv_max_hosts = true,
  srv_service_name = true,
  timeout_ms = true,
  tls = true,
  tls_allow_invalid_certificates = true,
  tls_allow_invalid_hostnames = true,
  tls_ca_file = true,
  tls_certificate_key_file = true,
  tls_certificate_key_file_password = true,
  tls_disable_certificate_revocation_check = true,
  tls_disable_ocsp_endpoint_check = true,
  tls_insecure = true,
  wait_queue_timeout_ms = true,
}

local BOOLEAN_OPTIONS = {
  direct_connection = true,
  journal = true,
  load_balanced = true,
  retry_reads = true,
  retry_writes = true,
  server_selection_try_once = true,
  tls = true,
  tls_allow_invalid_certificates = true,
  tls_allow_invalid_hostnames = true,
  tls_disable_certificate_revocation_check = true,
  tls_disable_ocsp_endpoint_check = true,
  tls_insecure = true,
}

local NON_NEGATIVE_INTEGER_OPTIONS = {
  connect_timeout_ms = true,
  local_threshold_ms = true,
  max_idle_time_ms = true,
  max_pool_size = true,
  min_pool_size = true,
  server_selection_timeout_ms = true,
  socket_timeout_ms = true,
  srv_max_hosts = true,
  timeout_ms = true,
  wait_queue_timeout_ms = true,
  w_timeout_ms = true,
}

local POSITIVE_INTEGER_OPTIONS = {
  max_connecting = true,
}

local STRING_OPTIONS = {
  app_name = true,
  auth_mechanism = true,
  auth_source = true,
  replica_set = true,
  srv_service_name = true,
  tls_ca_file = true,
  tls_certificate_key_file = true,
  tls_certificate_key_file_password = true,
}

local READ_PREFERENCE_MODES = {
  nearest = "nearest",
  primary = "primary",
  primaryPreferred = "primary_preferred",
  primary_preferred = "primary_preferred",
  secondary = "secondary",
  secondaryPreferred = "secondary_preferred",
  secondary_preferred = "secondary_preferred",
}

local TLS_CONFLICTS = {
  { "tls_insecure", "tls_allow_invalid_certificates" },
  { "tls_insecure", "tls_allow_invalid_hostnames" },
  { "tls_insecure", "tls_disable_ocsp_endpoint_check" },
  { "tls_insecure", "tls_disable_certificate_revocation_check" },
  { "tls_allow_invalid_certificates", "tls_disable_ocsp_endpoint_check" },
  { "tls_allow_invalid_certificates", "tls_disable_certificate_revocation_check" },
  { "tls_disable_ocsp_endpoint_check", "tls_disable_certificate_revocation_check" },
}

local DEFAULTS = {
  connect_timeout_ms = 10000,
  direct_connection = false,
  heartbeat_frequency_ms = 10000,
  local_threshold_ms = 15,
  max_connecting = 2,
  max_idle_time_ms = 0,
  max_pool_size = 100,
  min_pool_size = 0,
  retry_reads = true,
  retry_writes = true,
  server_monitoring_mode = "auto",
  server_selection_timeout_ms = 30000,
  server_selection_try_once = true,
  tls = false,
}

local function config_error(option, message)
  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    details = { option = option },
    message = message,
  })
end

local function immutable_value()
  error("driver options are immutable", 2)
end

local function readonly_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end

  seen = seen or {}

  if seen[value] then
    return seen[value]
  end

  local data = {}
  local proxy = {}

  seen[value] = proxy

  for key, item in pairs(value) do
    data[key] = readonly_copy(item, seen)
  end

  setmetatable(proxy, {
    __index = data,
    __len = function()
      return #data
    end,
    __metatable = "mongodb.config.options",
    __newindex = immutable_value,
    __pairs = function()
      return next, data, nil
    end,
  })

  return proxy
end

local function copy_defaults()
  local values = {}

  for key, value in pairs(DEFAULTS) do
    values[key] = value
  end

  return values
end

local function parse_uri_boolean(option, value)
  if value == "true" then
    return true
  end

  if value == "false" then
    return false
  end

  return config_error(option, option .. " must be 'true' or 'false'")
end

local function parse_uri_integer(option, value, allow_negative_one)
  if not value:match(allow_negative_one and "^%-?%d+$" or "^%d+$") then
    return config_error(option, option .. " must be an integer")
  end

  local number = tonumber(value)

  if math.type(number) ~= "integer" then
    return config_error(option, option .. " is outside the supported integer range")
  end

  return number
end

local function parse_pairs(option, value)
  local result = {}

  if value == "" then
    return result
  end

  for pair in (value .. ","):gmatch("(.-),") do
    local colon = pair:find(":", 1, true)

    if not colon or colon == 1 then
      return config_error(option, option .. " must contain comma-separated key:value pairs")
    end

    result[pair:sub(1, colon - 1)] = pair:sub(colon + 1)
  end

  return result
end

local function require_table_keys(option, value, allowed)
  if type(value) ~= "table" then
    return config_error(option, option .. " must be a table")
  end

  for key in pairs(value) do
    if not allowed[key] then
      return config_error(option .. "." .. tostring(key), "unsupported " .. option .. " field")
    end
  end

  return true
end

local function validate_integer(option, value, minimum)
  if math.type(value) ~= "integer" or value < minimum then
    return config_error(
      option,
      option .. " must be an integer greater than or equal to " .. minimum
    )
  end

  return value
end

local function validate_string(option, value, allow_empty)
  if type(value) ~= "string" or (not allow_empty and value == "") then
    local expected = allow_empty and "string" or "non-empty string"

    return config_error(option, option .. " must be a " .. expected)
  end

  if utf8.len(value) == nil then
    return config_error(option, option .. " must be valid UTF-8")
  end

  return value
end

local function validate_srv_service_name(value)
  local normalized, err = validate_string("srv_service_name", value, false)

  if not normalized then
    return nil, err
  end

  local valid_characters = normalized:match("^[%a%d]$")
    or normalized:match("^[%a%d][%a%d%-]*[%a%d]$")

  if #normalized > 62
      or not valid_characters
      or not normalized:match("%a") then
    return config_error(
      "srv_service_name",
      "srv_service_name must be a valid DNS service name of at most 62 bytes"
    )
  end

  return normalized
end

local function validate_tag_sets(value)
  if type(value) ~= "table" then
    return config_error("read_preference.tag_sets", "read preference tag_sets must be an array")
  end

  local result = {}

  for index = 1, #value do
    local tags = value[index]

    if type(tags) ~= "table" then
      return config_error(
        "read_preference.tag_sets",
        "each read preference tag set must be a table"
      )
    end

    local copy = {}

    for key, item in pairs(tags) do
      if type(key) ~= "string" or key == "" or type(item) ~= "string" then
        return config_error(
          "read_preference.tag_sets",
          "read preference tags must use non-empty string keys and string values"
        )
      end

      copy[key] = item
    end

    result[index] = copy
  end

  for key in pairs(value) do
    if math.type(key) ~= "integer" or key < 1 or key > #value then
      return config_error(
        "read_preference.tag_sets",
        "read preference tag_sets must be a dense array"
      )
    end
  end

  return result
end

local function apply_option(state, option, value, from_uri)
  local normalized = value
  local normalization_err

  if BOOLEAN_OPTIONS[option] then
    if from_uri then
      normalized, normalization_err = parse_uri_boolean(option, value)
    elseif type(value) ~= "boolean" then
      return config_error(option, option .. " must be a boolean")
    end
  elseif NON_NEGATIVE_INTEGER_OPTIONS[option] then
    if from_uri then
      normalized, normalization_err = parse_uri_integer(option, value, false)
    end

    if normalized ~= nil then
      normalized, normalization_err = validate_integer(option, normalized, 0)
    end
  elseif POSITIVE_INTEGER_OPTIONS[option] then
    if from_uri then
      normalized, normalization_err = parse_uri_integer(option, value, false)
    end

    if normalized ~= nil then
      normalized, normalization_err = validate_integer(option, normalized, 1)
    end
  elseif STRING_OPTIONS[option] then
    if option == "srv_service_name" then
      normalized, normalization_err = validate_srv_service_name(value)
    else
      normalized, normalization_err = validate_string(option, value, false)
    end

    if option == "app_name" and normalized and #normalized > 128 then
      return config_error(option, "app_name must not exceed 128 bytes")
    end
  elseif option == "heartbeat_frequency_ms" then
    if from_uri then
      normalized, normalization_err = parse_uri_integer(option, value, false)
    end

    if normalized ~= nil then
      normalized, normalization_err = validate_integer(option, normalized, 500)
    end
  elseif option == "max_staleness_seconds" then
    if from_uri then
      normalized, normalization_err = parse_uri_integer(option, value, true)
    end

    if normalized ~= nil and normalized ~= -1 then
      normalized, normalization_err = validate_integer(option, normalized, 90)
    end
  elseif option == "read_concern_level" then
    normalized, normalization_err = validate_string(option, value, true)
  elseif option == "read_preference_mode" then
    normalized = READ_PREFERENCE_MODES[value]

    if not normalized then
      return config_error(option, "unsupported read preference mode")
    end
  elseif option == "read_preference_tags" then
    if from_uri then
      normalized, normalization_err = parse_pairs(option, value)
    else
      normalized, normalization_err = validate_tag_sets(value)
    end
  elseif option == "server_monitoring_mode" then
    if value ~= "auto" and value ~= "poll" and value ~= "stream" then
      return config_error(option, "server_monitoring_mode must be auto, poll, or stream")
    end
  elseif option == "auth_mechanism_properties" then
    if from_uri then
      normalized, normalization_err = parse_pairs(option, value)
    elseif type(value) ~= "table" then
      return config_error(option, "auth_mechanism_properties must be a table")
    else
      for key, item in pairs(value) do
        local valid_oidc_callback = (key == "OIDC_CALLBACK"
          or key == "OIDC_HUMAN_CALLBACK") and type(item) == "function"
        local valid_oidc_allowed_hosts = key == "ALLOWED_HOSTS"
          and type(item) == "table"

        if type(key) ~= "string" or key == ""
            or (type(item) ~= "string" and not valid_oidc_callback
              and not valid_oidc_allowed_hosts)
        then
          return config_error(
            option,
            "auth_mechanism_properties contains an unsupported key or value type"
          )
        end
      end
    end
  elseif option == "w" then
    if from_uri and value:match("^%-?%d+$") then
      normalized, normalization_err = parse_uri_integer(option, value, false)
    end

    if math.type(normalized) == "integer" then
      normalized, normalization_err = validate_integer(option, normalized, 0)
    elseif type(normalized) ~= "string" or normalized == "" then
      return config_error(option, "w must be a non-negative integer or non-empty string")
    end
  else
    return config_error(option, "unsupported driver option")
  end

  if normalized == nil then
    return nil, normalization_err
  end

  state.values[option] = normalized
  state.seen[option] = true
  return true
end

local function apply_uri_options(state, uri_options)
  if uri_options == nil then
    return true
  end

  if type(uri_options) ~= "table" then
    error("URI options must be an ordered option array", 3)
  end

  local tls_values = {}
  local uri_seen = {}
  local has_w_timeout_ms = false

  for index = 1, #uri_options do
    if uri_options[index].key == "wtimeoutms" then
      has_w_timeout_ms = true
    end
  end

  for index = 1, #uri_options do
    local pair = uri_options[index]

    if type(pair) ~= "table" or type(pair.key) ~= "string" or type(pair.value) ~= "string" then
      error("URI options must contain key/value string pairs", 3)
    end

    local option = URI_NAMES[pair.key]

    if not option then
      state.warnings[#state.warnings + 1] = "unsupported MongoDB URI option: " .. pair.key
    elseif pair.key == "wtimeout" and has_w_timeout_ms then
      state.warnings[#state.warnings + 1] = "deprecated URI option ignored: wtimeout"
    else
      if uri_seen[option] and option ~= "read_preference_tags" and option ~= "tls" then
        state.warnings[#state.warnings + 1] = "duplicate MongoDB URI option: " .. option
      end

      uri_seen[option] = true
      local skip = false

      if pair.key == "wtimeout" then
        state.warnings[#state.warnings + 1] = "deprecated MongoDB URI option: wtimeout"
      end

      if pair.key == "tls" or pair.key == "ssl" then
        local tls_value = parse_uri_boolean("tls", pair.value)

        if tls_value == nil then
          state.warnings[#state.warnings + 1] = "invalid MongoDB URI option: tls"
          skip = true
        else
          tls_values[#tls_values + 1] = tls_value
        end
      end

      if not skip and option == "read_preference_tags" then
        local tags = parse_pairs(option, pair.value)

        if not tags then
          state.warnings[#state.warnings + 1] = "invalid MongoDB URI option: " .. option
        else
          state.values.read_preference_tags = state.values.read_preference_tags or {}
          state.values.read_preference_tags[#state.values.read_preference_tags + 1] = tags
          state.seen.read_preference_tags = true
        end
      elseif not skip then
        local applied, apply_err = apply_option(state, option, pair.value, true)

        if not applied then
          if option == "auth_source" then
            return nil, apply_err
          end

          state.warnings[#state.warnings + 1] = "invalid MongoDB URI option: " .. option
        end
      end
    end
  end

  for index = 2, #tls_values do
    if tls_values[index] ~= tls_values[1] then
      return config_error("tls", "tls and ssl URI options must agree")
    end
  end

  return true
end

local function apply_read_concern(state, value)
  local valid, err = require_table_keys("read_concern", value, { level = true })

  if not valid then
    return nil, err
  end

  if value.level ~= nil then
    return apply_option(state, "read_concern_level", value.level, false)
  end

  state.values.read_concern_level = nil
  state.seen.read_concern_level = true
  return true
end

local function apply_write_concern(state, value)
  local allowed = { journal = true, w = true, w_timeout_ms = true }
  local valid, err = require_table_keys("write_concern", value, allowed)

  if not valid then
    return nil, err
  end

  for _, option in ipairs({ "journal", "w", "w_timeout_ms" }) do
    if value[option] ~= nil then
      local applied, apply_err = apply_option(state, option, value[option], false)

      if not applied then
        return nil, apply_err
      end
    else
      state.values[option] = nil
      state.seen[option] = true
    end
  end

  return true
end

local function apply_read_preference(state, value)
  local allowed = { max_staleness_seconds = true, mode = true, tag_sets = true }
  local valid, err = require_table_keys("read_preference", value, allowed)

  if not valid then
    return nil, err
  end

  for key, option in pairs({
    max_staleness_seconds = "max_staleness_seconds",
    mode = "read_preference_mode",
    tag_sets = "read_preference_tags",
  }) do
    if value[key] ~= nil then
      local applied, apply_err = apply_option(state, option, value[key], false)

      if not applied then
        return nil, apply_err
      end
    end
  end

  return true
end

local function apply_server_api(state, value)
  local allowed = { deprecation_errors = true, strict = true, version = true }
  local valid, err = require_table_keys("server_api", value, allowed)

  if not valid then
    return nil, err
  end

  if value.version ~= "1" then
    return config_error("server_api.version", "server_api version must be '1'")
  end

  for _, option in ipairs({ "strict", "deprecation_errors" }) do
    if value[option] ~= nil and type(value[option]) ~= "boolean" then
      return config_error("server_api." .. option, "server_api flags must be booleans")
    end
  end

  state.values.server_api = {
    deprecation_errors = value.deprecation_errors,
    strict = value.strict,
    version = value.version,
  }
  state.seen.server_api = true
  return true
end

local function apply_programmatic_options(state, programmatic)
  if programmatic == nil then
    return true
  end

  if type(programmatic) ~= "table" then
    error("programmatic options must be a table", 3)
  end

  for option, value in pairs(programmatic) do
    local applied, err

    if PROGRAMMATIC_NAMES[option] then
      applied, err = apply_option(state, option, value, false)
    elseif option == "read_concern" then
      applied, err = apply_read_concern(state, value)
    elseif option == "read_preference" then
      applied, err = apply_read_preference(state, value)
    elseif option == "server_api" then
      applied, err = apply_server_api(state, value)
    elseif option == "write_concern" then
      applied, err = apply_write_concern(state, value)
    else
      return config_error(option, "unsupported programmatic driver option")
    end

    if not applied then
      return nil, err
    end
  end

  return true
end

local function validate_combinations(state)
  local values = state.values

  if not state.seen.tls then
    for option in pairs(state.seen) do
      if option:sub(1, 4) == "tls_" then
        values.tls = true
        break
      end
    end
  end

  if values.max_pool_size > 0 and values.min_pool_size > values.max_pool_size then
    return config_error("min_pool_size", "min_pool_size must not exceed max_pool_size")
  end

  if values.w == 0 and values.journal == true then
    return config_error("write_concern", "w=0 cannot be combined with journal=true")
  end

  local mode = values.read_preference_mode or "primary"
  local tag_sets = values.read_preference_tags or { {} }
  local max_staleness = values.max_staleness_seconds or -1

  if mode == "primary" and (#tag_sets ~= 1 or next(tag_sets[1]) ~= nil) then
    return config_error("read_preference", "primary read preference cannot use tag sets")
  end

  if mode == "primary" and max_staleness ~= -1 then
    return config_error("read_preference", "primary read preference cannot use max staleness")
  end

  for _, conflict in ipairs(TLS_CONFLICTS) do
    if state.seen[conflict[1]] and state.seen[conflict[2]] then
      return config_error("tls", "conflicting TLS options were specified")
    end
  end

  return true
end

local function build_result(values)
  local result = {}

  for option, value in pairs(values) do
    if option ~= "journal" and option ~= "max_staleness_seconds"
      and option ~= "read_concern_level" and option ~= "read_preference_mode"
      and option ~= "read_preference_tags" and option ~= "w" and option ~= "w_timeout_ms"
    then
      result[option] = value
    end
  end

  result.read_concern = {}

  if values.read_concern_level ~= nil then
    result.read_concern.level = values.read_concern_level
  end

  result.read_preference = {
    max_staleness_seconds = values.max_staleness_seconds or -1,
    mode = values.read_preference_mode or "primary",
    tag_sets = values.read_preference_tags or { {} },
  }
  result.write_concern = {}

  if values.journal ~= nil then
    result.write_concern.journal = values.journal
  end

  if values.w ~= nil then
    result.write_concern.w = values.w
  end

  if values.w_timeout_ms ~= nil then
    result.write_concern.w_timeout_ms = values.w_timeout_ms
  end

  return readonly_copy(result)
end

function M.normalize(uri_options, programmatic, uri_context)
  local state = { seen = {}, values = copy_defaults(), warnings = {} }
  local applied, err = apply_uri_options(state, uri_options)

  if not applied then
    return nil, err
  end

  applied, err = apply_programmatic_options(state, programmatic)

  if not applied then
    return nil, err
  end

  if uri_context ~= nil and type(uri_context) ~= "table" then
    error("URI context must be a parsed URI table", 2)
  end

  if uri_context and uri_context.is_srv and not state.seen.tls then
    state.values.tls = true
  end

  applied, err = validate_combinations(state)

  if not applied then
    return nil, err
  end

  return build_result(state.values), nil, readonly_copy(state.warnings)
end

function M.validate_uri(parsed, config)
  if type(parsed) ~= "table" or type(config) ~= "table" then
    error("URI validation requires parsed URI and normalized options tables", 2)
  end

  if config.direct_connection and #parsed.hosts ~= 1 then
    return config_error(
      "direct_connection",
      "directConnection=true requires exactly one seed"
    )
  end

  if config.load_balanced then
    if #parsed.hosts ~= 1 then
      return config_error(
        "load_balanced",
        "loadBalanced=true requires exactly one seed"
      )
    end

    if config.replica_set ~= nil then
      return config_error(
        "load_balanced",
        "loadBalanced=true cannot be combined with replicaSet"
      )
    end

    if config.direct_connection then
      return config_error(
        "load_balanced",
        "loadBalanced=true cannot be combined with directConnection=true"
      )
    end
  end

  if parsed.is_srv then
    if config.direct_connection then
      return config_error(
        "direct_connection",
        "directConnection=true cannot be used with mongodb+srv"
      )
    end

    if config.srv_max_hosts and config.srv_max_hosts > 0 then
      if config.replica_set ~= nil then
        return config_error(
          "srv_max_hosts",
          "srvMaxHosts cannot be combined with replicaSet"
        )
      end

      if config.load_balanced then
        return config_error(
          "srv_max_hosts",
          "srvMaxHosts cannot be combined with loadBalanced=true"
        )
      end
    end
  elseif config.srv_service_name ~= nil or config.srv_max_hosts ~= nil then
    return config_error(
      "srv_service_name",
      "srvServiceName and srvMaxHosts require a mongodb+srv URI"
    )
  end

  return true
end

return M
