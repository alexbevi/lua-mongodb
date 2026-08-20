local bson = require("mongodb.bson")
local luassert = require("luassert")
local options = require("mongodb.config.options")
local uri = require("mongodb.config.uri")

local M = {}

local ROOT = os.getenv("PWD") or "."
local SOURCE = ROOT .. "/planning/specifications/source/"

local URI_FIXTURES = {
  "auth-options.json",
  "compression-options.json",
  "concern-options.json",
  "connection-options.json",
  "connection-pool-options.json",
  "read-preference-options.json",
  "sdam-options.json",
  "single-threaded-options.json",
  "srv-options.json",
  "tls-options.json",
}

local OPTION_PATHS = {
  appname = { "app_name" },
  authMechanism = { "auth_mechanism" },
  authMechanismProperties = { "auth_mechanism_properties" },
  authSource = { "auth_source" },
  connectTimeoutMS = { "connect_timeout_ms" },
  compressors = { "compressors" },
  directConnection = { "direct_connection" },
  heartbeatFrequencyMS = { "heartbeat_frequency_ms" },
  journal = { "write_concern", "journal" },
  loadBalanced = { "load_balanced" },
  localThresholdMS = { "local_threshold_ms" },
  maxConnecting = { "max_connecting" },
  maxIdleTimeMS = { "max_idle_time_ms" },
  maxPoolSize = { "max_pool_size" },
  maxStalenessSeconds = { "read_preference", "max_staleness_seconds" },
  minPoolSize = { "min_pool_size" },
  readConcernLevel = { "read_concern", "level" },
  readPreference = { "read_preference", "mode" },
  readPreferenceTags = { "read_preference", "tag_sets" },
  replicaSet = { "replica_set" },
  retryWrites = { "retry_writes" },
  serverMonitoringMode = { "server_monitoring_mode" },
  serverSelectionTimeoutMS = { "server_selection_timeout_ms" },
  serverSelectionTryOnce = { "server_selection_try_once" },
  socketTimeoutMS = { "socket_timeout_ms" },
  srvMaxHosts = { "srv_max_hosts" },
  srvServiceName = { "srv_service_name" },
  timeoutMS = { "timeout_ms" },
  tls = { "tls" },
  tlsAllowInvalidCertificates = { "tls_allow_invalid_certificates" },
  tlsAllowInvalidHostnames = { "tls_allow_invalid_hostnames" },
  tlsCAFile = { "tls_ca_file" },
  tlsCertificateKeyFile = { "tls_certificate_key_file" },
  tlsCertificateKeyFilePassword = { "tls_certificate_key_file_password" },
  tlsDisableCertificateRevocationCheck = {
    "tls_disable_certificate_revocation_check",
  },
  tlsDisableOCSPEndpointCheck = { "tls_disable_ocsp_endpoint_check" },
  tlsInsecure = { "tls_insecure" },
  w = { "write_concern", "w" },
  wTimeoutMS = { "write_concern", "w_timeout_ms" },
  zlibCompressionLevel = { "zlib_compression_level" },
}

local READ_PREFERENCE_MODES = {
  primaryPreferred = "primary_preferred",
  secondaryPreferred = "secondary_preferred",
}

local function load_fixture(relative)
  local file = assert(io.open(SOURCE .. relative, "rb"))
  local fixture = assert(bson.json.decode(file:read("*a")))

  file:close()
  return fixture
end

local function plain(value)
  if bson.is_exact(value) then
    return value:to_number()
  end

  if bson.is_null(value) then
    return nil
  end

  if bson.is_array(value) then
    local result = {}

    for index, item in value:iter() do
      result[index] = plain(item)
    end

    return result
  end

  if bson.is_document(value) then
    local result = {}

    for key, item in value:iter() do
      result[key] = plain(item)
    end

    return result
  end

  return value
end

local function iter(value)
  if bson.is_array(value) or bson.is_document(value) then
    return value:iter()
  end

  return next, value, nil
end

local function is_empty(value)
  local empty = true

  for _ in pairs(value) do
    empty = false
  end

  return empty
end

local function option_value(config, name)
  local path = assert(OPTION_PATHS[name], "unmapped URI option: " .. name)
  local value = config

  for _, component in ipairs(path) do
    value = value[component]
  end

  return plain(value)
end

local function combined_warnings(parsed, normalized)
  local result = {}

  for _, source in ipairs({ parsed and parsed.warnings or {}, normalized or {} }) do
    for index = 1, #source do
      result[#result + 1] = source[index]
    end
  end

  return result
end

local function normalize_uri(value)
  local parsed, parse_err = uri.parse(value)

  if not parsed then
    return nil, parse_err, {}
  end

  local config, config_err, warnings = options.normalize(parsed.options, nil, parsed)

  if not config then
    return nil, config_err, combined_warnings(parsed, warnings)
  end

  local valid, validation_err = options.validate_uri(parsed, config)

  if not valid then
    return nil, validation_err, combined_warnings(parsed, warnings)
  end

  return config, nil, combined_warnings(parsed, warnings)
end

local function applicable_uri_case(name, index)
  if name == "auth-options.json" and index == 1 then
    return false
  end

  if name == "connection-options.json" and index >= 18 and index <= 24 then
    return false
  end

  return true
end

function M.run_uri_options()
  local count = 0

  for _, name in ipairs(URI_FIXTURES) do
    local fixture = load_fixture("uri-options/tests/" .. name)

    for index, test in fixture:get("tests"):iter() do
      if applicable_uri_case(name, index) then
        local description = name .. ": " .. test:get("description")
        local config, err, warnings = normalize_uri(test:get("uri"))
        local valid = test:get("valid")

        assert((config ~= nil) == valid, description)

        if valid then
          assert(err == nil, description)
          assert((#warnings > 0) == test:get("warning"), description .. ": warning")

          for option, expected in iter(test:get("options")) do
            local expected_value = plain(expected)

            if option == "readPreference" then
              expected_value = READ_PREFERENCE_MODES[expected_value] or expected_value
            end

            luassert.same(
              expected_value,
              option_value(config, option),
              description .. ": " .. option
            )
          end
        end

        count = count + 1
      end
    end
  end

  return count
end

local function write_concern_input(document)
  local result = {}

  for key, value in document:iter() do
    if key == "wtimeoutMS" then
      result.w_timeout_ms = plain(value)
    else
      result[key] = plain(value)
    end
  end

  return result
end

local function write_concern_document(concern)
  local result = {}

  if concern.journal ~= nil then
    result.j = concern.journal
  end

  if concern.w ~= nil then
    result.w = concern.w
  end

  if concern.w_timeout_ms ~= nil then
    result.wtimeout = concern.w_timeout_ms
  end

  return result
end

local function assert_connection_concern(test, config, description)
  local expected_read = test:get("readConcern")

  if expected_read and not bson.is_null(expected_read) then
    luassert.same(plain(expected_read), plain(config.read_concern), description)
  end

  local expected_write = test:get("writeConcern")

  if expected_write and not bson.is_null(expected_write) then
    luassert.same(
      write_concern_input(expected_write),
      plain(config.write_concern),
      description
    )
  end
end

local function run_connection_concern_fixture(relative)
  local fixture = load_fixture(relative)
  local count = 0

  for _, test in fixture:get("tests"):iter() do
    local description = relative .. ": " .. test:get("description")
    local config, _, warnings = normalize_uri(test:get("uri"))

    if test:get("valid") then
      assert(config ~= nil, description)
      assert_connection_concern(test, config, description)
    else
      local warning = test:get("warning")

      if bson.is_null(warning) or warning == true then
        assert(config == nil or #warnings > 0, description)
      else
        assert(config == nil, description)
      end
    end

    count = count + 1
  end

  return count
end

local function run_document_concern_fixture(relative)
  local fixture = load_fixture(relative)
  local count = 0

  for _, test in fixture:get("tests"):iter() do
    local description = relative .. ": " .. test:get("description")
    local read = test:get("readConcern")
    local write = test:get("writeConcern")
    local input = {}

    if read and not bson.is_null(read) then
      input.read_concern = plain(read)
    end

    if write and not bson.is_null(write) then
      input.write_concern = write_concern_input(write)
    end

    local config = options.normalize(nil, input)

    if test:get("valid") then
      assert(config ~= nil, description)

      if input.read_concern then
        luassert.same(
          plain(test:get("readConcernDocument")),
          plain(config.read_concern),
          description .. ": document"
        )
        assert(
          is_empty(config.read_concern) == test:get("isServerDefault"),
          description .. ": default"
        )
      end

      if input.write_concern then
        luassert.same(
          plain(test:get("writeConcernDocument")),
          write_concern_document(config.write_concern),
          description .. ": document"
        )
        assert(
          is_empty(config.write_concern) == test:get("isServerDefault"),
          description .. ": default"
        )
        assert(
          (config.write_concern.w ~= 0) == test:get("isAcknowledged"),
          description .. ": acknowledged"
        )
      end
    else
      assert(config == nil, description)
    end

    count = count + 1
  end

  return count
end

function M.run_read_write_concern()
  local count = 0

  for _, name in ipairs({ "read-concern.json", "write-concern.json" }) do
    count = count + run_connection_concern_fixture(
      "read-write-concern/tests/connection-string/" .. name
    )
    count = count + run_document_concern_fixture(
      "read-write-concern/tests/document/" .. name
    )
  end

  return count
end

return M
