local api = require("mongodb.api")
local auth = require("mongodb.auth")
local bson = require("mongodb.bson")
local command_executor = require("mongodb.command.executor")
local credentials = require("mongodb.config.credentials")
local driver_options = require("mongodb.config.options")
local dns_discovery = require("mongodb.discovery.dns")
local errors = require("mongodb.error")
local handshake_metadata = require("mongodb.handshake.metadata")
local monitoring = require("mongodb.monitoring")
local pool = require("mongodb.pool")
local runtime_contract = require("mongodb.runtime")
local retry_executor = require("mongodb.retry_executor")
local session_module = require("mongodb.session")
local session_executor = require("mongodb.session_executor")
local socket_timeout_executor = require("mongodb.socket_timeout_executor")
local standalone_executor = require("mongodb.standalone_executor")
local topology = require("mongodb.topology")
local topology_executor = require("mongodb.topology_executor")
local transport = require("mongodb.network.transport")
local uri_parser = require("mongodb.config.uri")

local M = {}

local SPECIAL_OPTIONS = {
  cancellation = true,
  command_listeners = true,
  deadline = true,
  driver_info = true,
  heartbeat_listeners = true,
  on_listener_error = true,
  pool_listeners = true,
  runtime = true,
  sdam_listeners = true,
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

local function append_compression_warnings(warnings, config, compression)
  compression = compression or {}

  for _, name in ipairs(config.compressors) do
    if compression[name] == nil then
      if name == "snappy" then
        warnings[#warnings + 1] = "wire protocol compression with snappy is not available; "
          .. "install lua-csnappy for Snappy support"
      elseif name == "zstd" then
        warnings[#warnings + 1] = "wire protocol compression with zstd is not available; "
          .. "install lua-zstd for Zstandard support"
      end
    end
  end
end

local function shallow_copy(value)
  if type(value) ~= "table" then
    return value
  end

  local result = {}

  for key, item in pairs(value) do
    result[key] = item
  end

  return result
end

local function lazy_object_ids(runtime)
  local generator
  local value = {}

  function value.new()
    if generator == nil then
      local err
      generator, err = bson.object_id_generator(runtime)

      if not generator then
        return nil, err
      end
    end

    return generator:new()
  end

  return value
end

local function session_id_factory(runtime)
  return function()
    local bytes, err = runtime.entropy:bytes(16)

    if not bytes then
      return nil, err
    end

    local values = { string.byte(bytes, 1, 16) }

    if #values ~= 16 then
      error("runtime entropy adapter returned an invalid session id", 0)
    end

    values[7] = values[7] & 0x0f | 0x40
    values[9] = values[9] & 0x3f | 0x80
    return bson.document({
      { "id", bson.binary(string.char(table.unpack(values)), bson.BINARY_SUBTYPE.UUID) },
    })
  end
end

local function transaction_jitter(runtime)
  return function()
    local bytes, err = runtime.entropy:bytes(4)

    if not bytes then
      return nil, err
    end

    if #bytes ~= 4 then
      error("runtime entropy adapter returned invalid transaction jitter", 0)
    end

    return string.unpack(">I4", bytes) / 0xffffffff
  end
end

local function transaction_concern(values, write)
  local entries = {}

  if write and values.journal ~= nil then
    entries[#entries + 1] = { "j", values.journal }
  end

  if values.level ~= nil then
    entries[#entries + 1] = { "level", values.level }
  end

  if write and values.w ~= nil then
    entries[#entries + 1] = { "w", values.w }
  end

  if write and values.w_timeout_ms ~= nil then
    entries[#entries + 1] = { "wtimeoutMS", values.w_timeout_ms }
  end

  return #entries > 0 and bson.document(entries) or nil
end

local function transaction_write_concern(value, retry)
  local entries = {}
  local has_timeout = false

  for key, item in (value or bson.document({})):iter() do
    if key ~= "w" then
      local field = key

      if key == "journal" then
        field = "j"
      elseif key == "wtimeoutMS" then
        field = "wtimeout"
        has_timeout = true
      elseif key == "wtimeout" then
        has_timeout = true
      end

      entries[#entries + 1] = { field, item }
    end
  end

  local w = retry and "majority" or value:get("w")

  if w ~= nil then
    entries[#entries + 1] = { "w", w }
  end

  if retry and not has_timeout then
    entries[#entries + 1] = { "wtimeout", 10000 }
  end

  return bson.document(entries)
end

local function public_client(
  executor,
  config,
  parsed,
  warnings,
  runtime,
  append_metadata,
  capabilities
)
  local err

  if capabilities == nil then
    capabilities, err = executor:capabilities()
  end

  if not capabilities then
    executor:close()
    return nil, err
  end

  local sessions
  local sessions_supported = config.load_balanced
    or capabilities.logical_session_timeout_minutes ~= nil
  local retryable_writes = config.retry_writes
    and sessions_supported
    and capabilities.max_wire_version >= 6
    and capabilities.server_type ~= "standalone"

  local timed = socket_timeout_executor.new(executor, runtime, config.socket_timeout_ms)
  local retrying = retry_executor.new(timed, {
    enabled_reads = config.retry_reads,
    enabled_writes = retryable_writes,
  })
  local decorated

  if sessions_supported then
    sessions = session_module.new({
      clock = runtime.clock,
      default_timeout_ms = config.timeout_ms,
      default_transaction_options = {
        read_concern = transaction_concern(config.read_concern, false),
        read_preference = config.read_preference,
        write_concern = transaction_concern(config.write_concern, true),
      },
      id_factory = session_id_factory(runtime),
      load_balanced = config.load_balanced,
      runtime = runtime,
      timeout_minutes = capabilities.logical_session_timeout_minutes,
      transaction_jitter = transaction_jitter(runtime),
      transaction_command = function(session, name, transaction_options, retry)
        local entries = { { name, 1 } }

        if name == "commitTransaction"
            and transaction_options.max_commit_time_ms ~= nil
        then
          entries[#entries + 1] = {
            "maxTimeMS",
            transaction_options.max_commit_time_ms,
          }
        end

        if retry and name == "commitTransaction" then
          entries[#entries + 1] = {
            "writeConcern",
            transaction_write_concern(
              transaction_options.write_concern,
              true
            ),
          }
        elseif transaction_options.write_concern ~= nil then
          entries[#entries + 1] = {
            "writeConcern",
            transaction_write_concern(
              transaction_options.write_concern,
              false
            ),
          }
        end

        local response, command_err = decorated:command(
          "admin",
          bson.document(entries),
          {
            session = session,
            transaction_control = true,
          }
        )
        local concern = response and response:get("writeConcernError")

        if bson.is_document(concern) then
          local labels = {}
          local response_labels = response:get("errorLabels")

          if bson.is_array(response_labels) then
            for _, label in response_labels:iter() do
              labels[#labels + 1] = label
            end
          end

          local code = concern:get("code")

          if bson.is_exact(code) then
            code = code:to_number()
          end

          return nil, errors.new({
            category = errors.CATEGORY.WRITE,
            code = code,
            code_name = concern:get("codeName"),
            details = { response = response },
            labels = labels,
            message = concern:get("errmsg") or "write concern failed",
          })
        end

        return response, command_err
      end,
    })
  end

  decorated = session_executor.new(retrying, sessions, {
    max_wire_version = capabilities.max_wire_version,
    retryable_writes = retryable_writes,
  })

  return api.new_client(
    decorated,
    config,
    parsed.database,
    warnings,
    lazy_object_ids(runtime),
    sessions,
    runtime,
    append_metadata,
    capabilities
  )
end

local function mechanism_from(hello, configured)
  if configured ~= nil then
    if configured ~= "PLAIN"
        and configured ~= "MONGODB-AWS"
        and configured ~= "MONGODB-OIDC"
        and configured ~= "MONGODB-X509"
        and configured ~= "SCRAM-SHA-1"
        and configured ~= "SCRAM-SHA-256"
    then
      return configuration_error("unsupported authentication mechanism")
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

local function host_from_address(value)
  local host
  local port

  if value:sub(1, 1) == "[" then
    local close = assert(value:find("]", 2, true))

    host = value:sub(2, close - 1)
    port = tonumber(value:sub(close + 2))
  else
    local colon = assert(value:match("^.*():"))

    host = value:sub(1, colon - 1)
    port = tonumber(value:sub(colon + 1))
  end

  return {
    host = host,
    port = port,
    type = host:find(":", 1, true) and "ip_literal" or "hostname",
  }
end

local function connection_deadline(runtime, config, deadline)
  if config.connect_timeout_ms == 0 then
    return deadline
  end

  local connect_deadline = runtime_contract.deadline_after(
    runtime,
    config.connect_timeout_ms / 1000
  )

  return deadline and math.min(deadline, connect_deadline) or connect_deadline
end

local function monitor_deadline(runtime, config, fields)
  if config.connect_timeout_ms == 0 then
    return fields.deadline
  end

  local timeout_ms = config.connect_timeout_ms + (fields.max_await_time_ms or 0)
  local deadline = runtime_contract.deadline_after(runtime, timeout_ms / 1000)

  return fields.deadline and math.min(fields.deadline, deadline) or deadline
end

local function open_executor(
  runtime,
  config,
  credential,
  monitor,
  metadata,
  server_address,
  fields,
  authenticate
)
  local host = host_from_address(server_address)
  local deadline = connection_deadline(runtime, config, fields.deadline)
  local connection, err = transport.connect(runtime, host.host, host.port, {
    cancellation = fields.cancellation,
    deadline = deadline,
    tls = tls_options(config, host),
  })

  if not connection then
    return nil, err
  end

  local executor = command_executor.new(connection, {
    compression = runtime.compression,
    compressors = config.compressors,
    load_balanced = config.load_balanced,
    metadata = metadata,
    monitoring = monitor,
    server = server_address,
    server_api = config.server_api,
    zlib_compression_level = config.zlib_compression_level,
  })
  local hello_options = {
    cancellation = fields.cancellation,
    deadline = connection_deadline(runtime, config, fields.deadline),
    max_await_time_ms = fields.max_await_time_ms,
    topology_version = fields.topology_version,
  }

  if credential ~= nil and credential.mechanism == nil and authenticate then
    hello_options.sasl_supported_mechs = credential.source .. "." .. credential.username
  end

  if credential ~= nil
      and credential.mechanism == "MONGODB-OIDC"
      and authenticate
  then
    local speculative_command

    speculative_command, err = auth.speculative_command(executor, credential)

    if err then
      executor:close()
      return nil, err
    end

    hello_options.speculative_authenticate = speculative_command
  end

  local hello
  hello, err = executor:hello(hello_options)

  if not hello then
    executor:close()
    return nil, err
  end

  if authenticate and credential ~= nil then
    local mechanism
    mechanism, err = mechanism_from(hello, credential.mechanism)

    if not mechanism then
      executor:close()
      return nil, err, hello
    end

    local authentication_commands = socket_timeout_executor.new(
      executor,
      runtime,
      config.socket_timeout_ms
    )
    local authenticated
    authenticated, err = auth.authenticate(authentication_commands, runtime, credential, {
      cancellation = fields.cancellation,
      deadline = fields.deadline,
      mechanism = mechanism,
      server_host = host.host,
      speculative_response = hello.document:get("speculativeAuthenticate"),
    })

    if not authenticated then
      executor:close()
      return nil, err, hello
    end

    if credential.mechanism == "MONGODB-OIDC" then
      local authenticated_executor = executor

      executor = retry_executor.new(authenticated_executor, {
        enabled = false,
        reauthenticate = function(options)
          assert(auth.invalidate(authenticated_executor, credential))
          return auth.authenticate(
            authenticated_executor,
            runtime,
            credential,
            {
              cancellation = options.cancellation,
              deadline = options.deadline,
              mechanism = mechanism,
              server_host = host.host,
            }
          )
        end,
      })
    end
  end

  return executor, nil, hello
end

local function load_balanced_capabilities(manager, config, special)
  local selected, pool_or_err = manager:select_server("write", nil, {
    cancellation = special.cancellation,
    deadline = special.deadline,
    timeout_ms = config.server_selection_timeout_ms,
  })

  if not selected then
    return nil, pool_or_err
  end

  local application_pool = pool_or_err
  local connection, err = application_pool:check_out({
    cancellation = special.cancellation,
    deadline = special.deadline,
  })

  if not connection then
    return nil, err
  end

  local capabilities = connection.resource:capabilities()

  assert(application_pool:check_in(connection))
  return capabilities
end

local function connect_topology(
  parsed,
  config,
  credential,
  special,
  runtime,
  monitor,
  metadata_state,
  warnings,
  append_metadata
)
  local seeds = {}

  for index, host in ipairs(parsed.hosts) do
    if host.type == "unix" then
      return configuration_error("Unix domain sockets are not supported by the current runtime")
    end

    seeds[index] = address(host)
  end

  local monitor_connections = {}
  local monitor_capabilities
  local manager
  local function monitor_check(server_address, fields)
    local executor = monitor_connections[server_address]
    local hello
    local err

    if executor then
      hello, err = executor:hello({
        cancellation = fields.cancellation,
        deadline = monitor_deadline(runtime, config, fields),
        max_await_time_ms = fields.max_await_time_ms,
        topology_version = fields.topology_version,
      })
    else
      executor, err, hello = open_executor(
        runtime,
        config,
        credential,
        monitor,
        metadata_state.value,
        server_address,
        fields,
        false
      )
      monitor_connections[server_address] = executor
    end

    if not hello then
      if executor then
        executor:close()
      end

      monitor_connections[server_address] = nil
      return nil, err
    end

    monitor_capabilities = hello
    return hello.document
  end

  local function rtt_check(server_address, fields)
    local started_at = runtime.clock:now()
    local executor = open_executor(
      runtime,
      config,
      credential,
      monitor,
      metadata_state.value,
      server_address,
      fields,
      false
    )

    if not executor then
      return nil
    end

    executor:close()
    return (runtime.clock:now() - started_at) * 1000
  end

  local function pool_factory(server_address)
    return pool.new({
      address = server_address,
      connect = function(fields)
        return open_executor(
          runtime,
          config,
          credential,
          monitor,
          metadata_state.value,
          server_address,
          fields,
          true
        )
      end,
      listeners = special.pool_listeners or {},
      max_connecting = config.max_connecting,
      max_idle_time_ms = config.max_idle_time_ms,
      max_pool_size = config.max_pool_size,
      min_pool_size = config.min_pool_size,
      on_connection_error = function(connection_err, connection_details)
        if manager then
          return manager:handle_application_error(server_address, {
            error = connection_err,
            generation = connection_details and connection_details.generation,
            service_id = connection_details and connection_details.service_id,
            type = "handshake",
            when = connection_details and connection_details.handshake_complete
              and "afterHandshakeCompletes" or "beforeHandshakeCompletes",
          })
        end
      end,
      on_listener_error = special.on_listener_error,
      runtime = runtime,
      wait_queue_timeout_ms = config.wait_queue_timeout_ms or 0,
    })
  end

  manager = topology.new({
    check = monitor_check,
    heartbeat_frequency_ms = config.heartbeat_frequency_ms,
    heartbeat_listeners = special.heartbeat_listeners,
    is_faas = handshake_metadata.is_faas(
      runtime.metadata and runtime.metadata.environment or {}
    ),
    listeners = special.sdam_listeners or {},
    on_listener_error = special.on_listener_error,
    on_server_close = function(server_address)
      local connection = monitor_connections[server_address]

      if connection then
        connection:close()
        monitor_connections[server_address] = nil
      end
    end,
    pool_factory = pool_factory,
    rtt_check = rtt_check,
    runtime = runtime,
    seeds = seeds,
    server_monitoring_mode = config.server_monitoring_mode,
    set_name = config.replica_set,
    srv = parsed.srv and {
      hostname = parsed.srv.hostname,
      max_hosts = config.srv_max_hosts or 0,
      minimum_ttl = parsed.srv.minimum_ttl,
      service_name = parsed.srv.service_name,
    } or nil,
    type = config.load_balanced and "LoadBalanced"
      or config.direct_connection and "Single"
      or config.replica_set ~= nil and "ReplicaSetNoPrimary"
      or "Unknown",
  })
  assert(manager:open())
  local executor = topology_executor.new(manager, {
    local_threshold_ms = config.local_threshold_ms,
    on_close = function()
      for server_address, connection in pairs(monitor_connections) do
        connection:close()
        monitor_connections[server_address] = nil
      end
    end,
    read_preference = config.read_preference,
    server_selection_timeout_ms = config.server_selection_timeout_ms,
  })
  local capabilities
  local err

  if config.load_balanced then
    capabilities, err = load_balanced_capabilities(manager, config, special)
  else
    local capabilities_deadline = runtime_contract.deadline_after(
      runtime,
      config.server_selection_timeout_ms / 1000
    )

    while monitor_capabilities == nil do
      local ok
      ok, err = runtime_contract.check(runtime, capabilities_deadline)

      if not ok then
        break
      end

      local remaining = runtime_contract.remaining(runtime, capabilities_deadline)

      assert(runtime.clock:sleep(math.min(0.01, remaining or math.huge)))
    end

    capabilities = monitor_capabilities

    if capabilities == nil then
      local selected, selection_err = manager:select_server(
        "write",
        nil,
        { timeout_ms = 0 }
      )

      assert(selected == nil)
      err = selection_err
    end
  end

  if not capabilities then
    executor:close()
    return nil, err
  end

  return public_client(
    executor,
    config,
    parsed,
    warnings,
    runtime,
    append_metadata,
    capabilities
  )
end

function M.connect(uri, values)
  local parsed, err = uri_parser.parse(uri)

  if not parsed then
    return nil, err
  end

  local programmatic, special = split_options(values)
  local runtime
  local config, config_err, option_warnings = driver_options.normalize(
    parsed.options,
    programmatic,
    parsed
  )

  if not config then
    return nil, config_err
  end

  if parsed.is_srv then
    runtime = special.runtime or runtime_contract.copas()
    runtime_contract.validate(runtime)
    parsed, config, option_warnings = dns_discovery.resolve(
      parsed,
      programmatic,
      runtime,
      {
        cancellation = special.cancellation,
        deadline = special.deadline,
      }
    )

    if parsed == nil then
      return nil, config
    end
  end

  local valid_uri, uri_err = driver_options.validate_uri(parsed, config)

  if not valid_uri then
    return nil, uri_err
  end

  local credential, credential_err = credentials.build(parsed, config)

  if credential_err then
    return nil, credential_err
  end

  runtime = runtime or special.runtime or runtime_contract.copas()

  runtime_contract.validate(runtime)
  local deadline = special.deadline

  local monitor = monitoring.new({
    clock = runtime.clock,
    listeners = special.command_listeners or {},
    on_listener_error = special.on_listener_error,
  })
  local metadata_facts = runtime.metadata or {}
  local driver_infos = {}

  if special.driver_info ~= nil then
    driver_infos[1] = handshake_metadata.normalize_driver_info(special.driver_info)
  end

  local metadata_options = {
    app_name = config.app_name,
    driver_infos = driver_infos,
    environment = shallow_copy(metadata_facts.environment),
    files = shallow_copy(metadata_facts.files),
    os = shallow_copy(metadata_facts.os),
    platform = metadata_facts.platform,
  }
  local metadata_state = { value = handshake_metadata.new(metadata_options) }
  local function append_metadata(driver_info)
    local updated_infos, added = handshake_metadata.append_driver_info(
      driver_infos,
      driver_info
    )

    if not added then
      return false
    end

    metadata_options.driver_infos = updated_infos
    local updated_metadata = handshake_metadata.new(metadata_options)

    driver_infos = updated_infos
    metadata_state.value = updated_metadata
    return true
  end
  local warnings = combine_warnings(parsed, option_warnings)

  append_compression_warnings(warnings, config, runtime.compression)

  if config.load_balanced or parsed.is_srv or config.replica_set ~= nil
      or config.min_pool_size > 0
      or special.pool_listeners ~= nil or special.sdam_listeners ~= nil
  then
    return connect_topology(
      parsed,
      config,
      credential,
      special,
      runtime,
      monitor,
      metadata_state,
      warnings,
      append_metadata
    )
  end

  if #parsed.hosts ~= 1 then
    return configuration_error(
      "multiple seeds require replicaSet; sharded deployments are post-v1"
    )
  end

  local host = parsed.hosts[1]

  if host.type == "unix" then
    return configuration_error("Unix domain sockets are not supported by the current runtime")
  end

  local server_address = address(host)
  local fields = {
    cancellation = special.cancellation,
    deadline = deadline,
  }
  local executor, hello

  executor, err, hello = open_executor(
    runtime,
    config,
    credential,
    monitor,
    metadata_state.value,
    server_address,
    fields,
    true
  )

  if not executor then
    return nil, err
  end

  if hello.server_type == "mongos" then
    executor:close()
    return connect_topology(
      parsed,
      config,
      credential,
      special,
      runtime,
      monitor,
      metadata_state,
      warnings,
      append_metadata
    )
  elseif hello.server_type ~= "standalone" then
    executor:close()
    return configuration_error("the standalone client cannot use this server topology")
  end

  local reconnecting = standalone_executor.new(executor, function(options)
    local replacement, replacement_err, replacement_hello = open_executor(
      runtime,
      config,
      credential,
      monitor,
      metadata_state.value,
      server_address,
      options,
      true
    )

    if replacement and replacement_hello.server_type ~= "standalone" then
      replacement:close()
      return configuration_error("the standalone client cannot use this server topology")
    end

    return replacement, replacement_err
  end, hello)

  return public_client(
    reconnecting,
    config,
    parsed,
    warnings,
    runtime,
    append_metadata
  )
end

return M
