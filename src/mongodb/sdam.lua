local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local uri_parser = require("mongodb.config.uri")
local errors = require("mongodb.error")

local M = {}

local SERVER_STATES = setmetatable({}, { __mode = "k" })
local TOPOLOGY_STATES = setmetatable({}, { __mode = "k" })
local SERVER_METHODS = {}
local TOPOLOGY_METHODS = {}

local TOPOLOGY_TYPE = {
  LOAD_BALANCED = "LoadBalanced",
  REPLICA_SET_NO_PRIMARY = "ReplicaSetNoPrimary",
  REPLICA_SET_WITH_PRIMARY = "ReplicaSetWithPrimary",
  SHARDED = "Sharded",
  SINGLE = "Single",
  UNKNOWN = "Unknown",
}

local SERVER_TYPE = {
  LOAD_BALANCER = "LoadBalancer",
  MONGOS = "Mongos",
  POSSIBLE_PRIMARY = "PossiblePrimary",
  RS_ARBITER = "RSArbiter",
  RS_GHOST = "RSGhost",
  RS_OTHER = "RSOther",
  RS_PRIMARY = "RSPrimary",
  RS_SECONDARY = "RSSecondary",
  STANDALONE = "Standalone",
  UNKNOWN = "Unknown",
}

local VALID_TOPOLOGY_TYPES = {}

for _, value in pairs(TOPOLOGY_TYPE) do
  VALID_TOPOLOGY_TYPES[value] = true
end

local DATA_BEARING_TYPES = {
  [SERVER_TYPE.LOAD_BALANCER] = true,
  [SERVER_TYPE.MONGOS] = true,
  [SERVER_TYPE.RS_PRIMARY] = true,
  [SERVER_TYPE.RS_SECONDARY] = true,
  [SERVER_TYPE.STANDALONE] = true,
}

local MEMBER_TYPES = {
  [SERVER_TYPE.RS_ARBITER] = true,
  [SERVER_TYPE.RS_OTHER] = true,
  [SERVER_TYPE.RS_SECONDARY] = true,
}

local function readonly_table(values, kind)
  return setmetatable({}, {
    __index = values,
    __len = function()
      return #values
    end,
    __metatable = "mongodb.sdam." .. kind,
    __newindex = function()
      error("SDAM descriptions are immutable", 2)
    end,
    __pairs = function()
      return next, values, nil
    end,
  })
end

M.TOPOLOGY_TYPE = readonly_table(TOPOLOGY_TYPE, "topology_types")
M.SERVER_TYPE = readonly_table(SERVER_TYPE, "server_types")

local function immutable(kind)
  return function()
    error(kind .. " descriptions are immutable", 2)
  end
end

local SERVER_METATABLE = {
  __index = function(value, key)
    if SERVER_METHODS[key] then
      return SERVER_METHODS[key]
    end

    local state = SERVER_STATES[value]

    if state then
      return state[key]
    end
  end,
  __metatable = "mongodb.sdam.server_description",
  __newindex = immutable("server"),
}

local TOPOLOGY_METATABLE = {
  __index = function(value, key)
    if TOPOLOGY_METHODS[key] then
      return TOPOLOGY_METHODS[key]
    end

    local state = TOPOLOGY_STATES[value]

    if state then
      return state[key]
    end
  end,
  __metatable = "mongodb.sdam.topology_description",
  __newindex = immutable("topology"),
}

local function topology_error(message, details)
  return errors.new({
    category = errors.CATEGORY.TOPOLOGY,
    details = details,
    message = message,
  })
end

local function number_value(value)
  if type(value) == "number" then
    return value
  end

  if bson.is_exact(value) then
    return value:to_number()
  end
end

local function nullable(value)
  if value == nil or bson.is_null(value) then
    return nil
  end

  return value
end

local function normalize_address(address)
  if type(address) ~= "string" or address == "" or utf8.len(address) == nil then
    return nil, "server address must be a non-empty UTF-8 string"
  end

  address = address:lower()

  if address:sub(1, 1) == "[" then
    local close = address:find("]", 2, true)

    if not close or close == 2 then
      return nil, "server address contains an invalid IPv6 literal"
    end

    local suffix = address:sub(close + 1)

    if suffix == "" then
      return address .. ":27017"
    end

    if not suffix:match("^:%d+$") then
      return nil, "server address contains an invalid port"
    end

    local port = tonumber(suffix:sub(2))

    if port < 1 or port > 65535 then
      return nil, "server address contains an invalid port"
    end

    return address
  end

  local first_colon = address:find(":", 1, true)

  if not first_colon then
    return address .. ":27017"
  end

  if address:find(":", first_colon + 1, true) then
    return nil, "IPv6 server addresses must be enclosed in brackets"
  end

  local port_text = address:sub(first_colon + 1)

  if not port_text:match("^%d+$") then
    return nil, "server address contains an invalid port"
  end

  local port = tonumber(port_text)

  if port < 1 or port > 65535 then
    return nil, "server address contains an invalid port"
  end

  return address
end

local function address_for_host(host)
  local name = host.host

  if name:find(":", 1, true) then
    name = "[" .. name .. "]"
  end

  return name:lower() .. ":" .. tostring(host.port or 27017)
end

local function list_from_set(values)
  local result = {}

  for value in pairs(values) do
    result[#result + 1] = value
  end

  table.sort(result)
  return readonly_table(result, "addresses")
end

local function parse_address_array(response, name)
  local value = response:get(name)
  local result = {}

  if value == nil or bson.is_null(value) then
    return result
  end

  if not bson.is_array(value) then
    return nil, name .. " must be a BSON array"
  end

  for _, address in value:iter() do
    local normalized, err = normalize_address(address)

    if not normalized then
      return nil, name .. " contains an invalid address: " .. err
    end

    result[normalized] = true
  end

  return result
end

local function topology_version(response)
  local value = nullable(response:get("topologyVersion"))

  if value == nil then
    return nil
  end

  if not bson.is_document(value) then
    return nil, "topologyVersion must be a BSON document"
  end

  local process_id = value:get("processId")
  local counter = number_value(value:get("counter"))

  if not bson.is_tagged(process_id, "object_id")
      or math.type(counter) ~= "integer" or counter < 0
  then
    return nil, "topologyVersion must contain an ObjectId processId and non-negative counter"
  end

  return value
end

local function error_server(address, message, options, current_topology_version)
  local value = {}
  local err = options and options.error

  if not errors.is(err) then
    if type(err) == "string" and err ~= "" then
      message = err
    end

    err = topology_error(message or "server check failed", { address = address })
  end

  local state = {
    address = address,
    arbiters = readonly_table({}, "addresses"),
    election_id = nil,
    error = err,
    generation = options and options.generation or 0,
    hosts = readonly_table({}, "addresses"),
    last_update_time = options and options.last_update_time,
    last_write_date = nil,
    logical_session_timeout_minutes = nil,
    max_bson_size = 16 * 1024 * 1024,
    max_message_size = 48000000,
    max_wire_version = 0,
    max_write_batch_size = 100000,
    me = nil,
    min_wire_version = 0,
    minimum_round_trip_time = nil,
    op_time = nil,
    passives = readonly_table({}, "addresses"),
    primary = nil,
    round_trip_time = nil,
    set_name = nil,
    set_version = nil,
    tags = bson.document({}),
    topology_version = current_topology_version,
    type = SERVER_TYPE.UNKNOWN,
  }

  SERVER_STATES[value] = state
  return setmetatable(value, SERVER_METATABLE)
end

local function load_balancer_server(address, options)
  local value = {}

  SERVER_STATES[value] = {
    address = address,
    all_hosts = {},
    arbiters = readonly_table({}, "addresses"),
    election_id = nil,
    error = nil,
    generation = options and options.generation or 0,
    hosts = readonly_table({}, "addresses"),
    last_update_time = options and options.last_update_time,
    last_write_date = nil,
    logical_session_timeout_minutes = nil,
    max_bson_size = nil,
    max_message_size = nil,
    max_wire_version = nil,
    max_write_batch_size = nil,
    me = nil,
    min_wire_version = nil,
    minimum_round_trip_time = nil,
    op_time = nil,
    passives = readonly_table({}, "addresses"),
    primary = nil,
    round_trip_time = nil,
    set_name = nil,
    set_version = nil,
    tags = bson.document({}),
    topology_version = nil,
    type = SERVER_TYPE.LOAD_BALANCER,
  }
  return setmetatable(value, SERVER_METATABLE)
end

local function valid_integer(response, name, default, minimum)
  local raw = nullable(response:get(name))

  if raw == nil then
    return default
  end

  local value = number_value(raw)

  if math.type(value) ~= "integer" or value < (minimum or 0) then
    return nil, name .. " must be an integer"
  end

  return value
end

local function server_type(response)
  if response:get("serviceId") ~= nil then
    return SERVER_TYPE.LOAD_BALANCER
  end

  if response:get("isreplicaset") == true then
    return SERVER_TYPE.RS_GHOST
  end

  if type(nullable(response:get("setName"))) == "string" then
    if response:get("hidden") == true then
      return SERVER_TYPE.RS_OTHER
    end

    local primary = response:get("isWritablePrimary")

    if primary == nil then
      primary = response:get("ismaster")
    end

    if primary == true then
      return SERVER_TYPE.RS_PRIMARY
    elseif response:get("secondary") == true then
      return SERVER_TYPE.RS_SECONDARY
    elseif response:get("arbiterOnly") == true then
      return SERVER_TYPE.RS_ARBITER
    end

    return SERVER_TYPE.RS_OTHER
  end

  if response:get("msg") == "isdbgrid" then
    return SERVER_TYPE.MONGOS
  end

  return SERVER_TYPE.STANDALONE
end

local function parse_server(address, response, options)
  options = options or {}

  if not bson.is_document(response) then
    error("hello response must be a BSON document", 3)
  end

  local ok = number_value(response:get("ok"))

  if ok ~= 1 then
    local message = nullable(response:get("errmsg"))

    if type(message) ~= "string" or message == "" then
      message = #response == 0 and "server check failed" or "hello response was not ok"
    end

    local version = topology_version(response)
    return error_server(address, message, options, version)
  end

  if response:get("serviceId") ~= nil then
    return load_balancer_server(address, options)
  end

  local hosts, parse_err = parse_address_array(response, "hosts")

  if not hosts then
    return error_server(address, parse_err, options)
  end

  local passives
  passives, parse_err = parse_address_array(response, "passives")

  if not passives then
    return error_server(address, parse_err, options)
  end

  local arbiters
  arbiters, parse_err = parse_address_array(response, "arbiters")

  if not arbiters then
    return error_server(address, parse_err, options)
  end

  local min_wire
  min_wire, parse_err = valid_integer(response, "minWireVersion", 0)

  if min_wire == nil then
    return error_server(address, parse_err, options)
  end

  local max_wire
  max_wire, parse_err = valid_integer(response, "maxWireVersion", 0)

  if max_wire == nil then
    return error_server(address, parse_err, options)
  end

  local set_version
  set_version, parse_err = valid_integer(response, "setVersion", nil)

  if parse_err then
    return error_server(address, parse_err, options)
  end

  local session_timeout
  session_timeout, parse_err = valid_integer(
    response,
    "logicalSessionTimeoutMinutes",
    nil
  )

  if parse_err then
    return error_server(address, parse_err, options)
  end

  local max_bson_size
  max_bson_size, parse_err = valid_integer(
    response,
    "maxBsonObjectSize",
    16 * 1024 * 1024,
    1
  )

  if parse_err then
    return error_server(address, parse_err, options)
  end

  local max_message_size
  max_message_size, parse_err = valid_integer(
    response,
    "maxMessageSizeBytes",
    48000000,
    1
  )

  if parse_err then
    return error_server(address, parse_err, options)
  end

  local max_write_batch_size
  max_write_batch_size, parse_err = valid_integer(
    response,
    "maxWriteBatchSize",
    100000,
    1
  )

  if parse_err then
    return error_server(address, parse_err, options)
  end

  local version
  version, parse_err = topology_version(response)

  if parse_err then
    return error_server(address, parse_err, options)
  end

  local me = nullable(response:get("me"))
  local primary = nullable(response:get("primary"))

  if me ~= nil then
    me, parse_err = normalize_address(me)

    if not me then
      return error_server(address, "me contains an invalid address: " .. parse_err, options)
    end
  end

  if primary ~= nil then
    primary, parse_err = normalize_address(primary)

    if not primary then
      return error_server(
        address,
        "primary contains an invalid address: " .. parse_err,
        options
      )
    end
  end

  local tags = nullable(response:get("tags")) or bson.document({})

  if not bson.is_document(tags) then
    return error_server(address, "tags must be a BSON document", options)
  end

  local election_id = nullable(response:get("electionId"))

  if election_id ~= nil and not bson.is_tagged(election_id, "object_id") then
    return error_server(address, "electionId must be an ObjectId", options)
  end

  local last_write = nullable(response:get("lastWrite"))
  local last_write_date
  local op_time

  if last_write ~= nil then
    if not bson.is_document(last_write) then
      return error_server(address, "lastWrite must be a BSON document", options)
    end

    last_write_date = nullable(last_write:get("lastWriteDate"))
    op_time = nullable(last_write:get("opTime"))
  end

  local all_hosts = {}

  for host in pairs(hosts) do
    all_hosts[host] = true
  end

  for host in pairs(passives) do
    all_hosts[host] = true
  end

  for host in pairs(arbiters) do
    all_hosts[host] = true
  end

  local value = {}

  SERVER_STATES[value] = {
    address = address,
    all_hosts = all_hosts,
    arbiters = list_from_set(arbiters),
    election_id = election_id,
    error = nil,
    generation = options.generation or 0,
    hosts = list_from_set(hosts),
    last_update_time = options.last_update_time,
    last_write_date = last_write_date,
    logical_session_timeout_minutes = session_timeout,
    max_bson_size = max_bson_size,
    max_message_size = max_message_size,
    max_wire_version = max_wire,
    max_write_batch_size = max_write_batch_size,
    me = me,
    min_wire_version = min_wire,
    minimum_round_trip_time = options.minimum_round_trip_time,
    op_time = op_time,
    passives = list_from_set(passives),
    primary = primary,
    round_trip_time = options.round_trip_time,
    set_name = nullable(response:get("setName")),
    set_version = set_version,
    tags = tags,
    topology_version = version,
    type = server_type(response),
  }
  return setmetatable(value, SERVER_METATABLE)
end

local function clone_server(server, changes)
  local source = SERVER_STATES[server]
  local state = {}

  for key, value in pairs(source) do
    state[key] = value
  end

  for key, value in pairs(changes or {}) do
    state[key] = value
  end

  local result = {}

  SERVER_STATES[result] = state
  return setmetatable(result, SERVER_METATABLE)
end

local function unknown_from(server, message)
  local state = SERVER_STATES[server]

  return error_server(state.address, message, {
    generation = state.generation,
    last_update_time = state.last_update_time,
  }, state.topology_version)
end

local function topology_version_is_stale(current, incoming)
  if current == nil or incoming == nil then
    return false
  end

  local current_process = current:get("processId")
  local incoming_process = incoming:get("processId")

  if current_process ~= incoming_process then
    return false
  end

  return number_value(incoming:get("counter")) < number_value(current:get("counter"))
end

local function compatibility(servers, client_min, client_max)
  for address, server in pairs(servers) do
    local state = SERVER_STATES[server]

    if state.type ~= SERVER_TYPE.LOAD_BALANCER
        and state.type ~= SERVER_TYPE.UNKNOWN
        and state.type ~= SERVER_TYPE.POSSIBLE_PRIMARY
    then
      if state.min_wire_version > client_max then
        return false, string.format(
          "Server at %s requires wire version %d, "
            .. "but this version of lua-mongodb only supports up to %d.",
          address,
          state.min_wire_version,
          client_max
        )
      elseif state.max_wire_version < client_min then
        return false, string.format(
          "Server at %s reports wire version %d, "
            .. "but this version of lua-mongodb requires at least %d (MongoDB 7.0).",
          address,
          state.max_wire_version,
          client_min
        )
      end
    end
  end

  return true
end

local function logical_session_timeout(servers)
  local found = false
  local minimum

  for _, server in pairs(servers) do
    local state = SERVER_STATES[server]

    if DATA_BEARING_TYPES[state.type] then
      found = true

      if state.logical_session_timeout_minutes == nil then
        return nil
      end

      if minimum == nil or state.logical_session_timeout_minutes < minimum then
        minimum = state.logical_session_timeout_minutes
      end
    end
  end

  return found and minimum or nil
end

local function new_topology(state)
  local compatible, compatibility_error = compatibility(
    state.servers,
    state.client_min_wire_version,
    state.client_max_wire_version
  )
  local public_servers = {}

  for address, server in pairs(state.servers) do
    public_servers[address] = server
  end

  state.compatible = compatible
  state.compatibility_error = compatibility_error
  state.logical_session_timeout_minutes = logical_session_timeout(state.servers)
  state.sessions_supported = state.type == TOPOLOGY_TYPE.LOAD_BALANCED
    or state.logical_session_timeout_minutes ~= nil
  state.servers_view = readonly_table(public_servers, "servers")
  local value = {}

  TOPOLOGY_STATES[value] = state
  return setmetatable(value, TOPOLOGY_METATABLE)
end

local function copy_topology(topology)
  local source = TOPOLOGY_STATES[topology]
  local servers = {}

  for address, server in pairs(source.servers) do
    servers[address] = server
  end

  return {
    client_max_wire_version = source.client_max_wire_version,
    client_min_wire_version = source.client_min_wire_version,
    max_election_id = source.max_election_id,
    max_set_version = source.max_set_version,
    seeds = source.seeds,
    servers = servers,
    set_name = source.set_name,
    type = source.type,
  }
end

local function has_primary(servers)
  for _, server in pairs(servers) do
    if SERVER_STATES[server].type == SERVER_TYPE.RS_PRIMARY then
      return TOPOLOGY_TYPE.REPLICA_SET_WITH_PRIMARY
    end
  end

  return TOPOLOGY_TYPE.REPLICA_SET_NO_PRIMARY
end

local function possible_primary(servers, address)
  local server = servers[address]

  if server and SERVER_STATES[server].type == SERVER_TYPE.UNKNOWN then
    servers[address] = clone_server(server, {
      error = nil,
      type = SERVER_TYPE.POSSIBLE_PRIMARY,
    })
  end
end

local function update_without_primary(state, server)
  local description = SERVER_STATES[server]

  if state.set_name == nil then
    state.set_name = description.set_name
  elseif state.set_name ~= description.set_name then
    state.servers[description.address] = nil
    return
  end

  for address in pairs(description.all_hosts) do
    if state.servers[address] == nil then
      state.servers[address] = error_server(address, "server has not been checked")
    end
  end

  if description.primary ~= nil then
    possible_primary(state.servers, description.primary)
  end

  if description.me ~= nil and description.address ~= description.me then
    state.servers[description.address] = nil
  end
end

local function update_with_primary_from_member(state, server)
  local description = SERVER_STATES[server]

  if state.set_name ~= description.set_name
      or description.me ~= nil and description.address ~= description.me
  then
    state.servers[description.address] = nil
  end

  state.type = has_primary(state.servers)

  if state.type == TOPOLOGY_TYPE.REPLICA_SET_NO_PRIMARY
      and description.primary ~= nil
  then
    possible_primary(state.servers, description.primary)
  end
end

local function compare_nullable(left, right)
  if left == nil then
    return right == nil and 0 or -1
  elseif right == nil then
    return 1
  elseif left < right then
    return -1
  elseif right < left then
    return 1
  end

  return 0
end

local function compare_post_17(description, state)
  local election = compare_nullable(description.election_id, state.max_election_id)

  if election ~= 0 then
    return election
  end

  return compare_nullable(description.set_version, state.max_set_version)
end

local function stale_primary(state, server)
  local description = SERVER_STATES[server]

  if description.max_wire_version >= 17 then
    if compare_post_17(description, state) < 0 then
      return true
    end

    state.max_election_id = description.election_id
    state.max_set_version = description.set_version
    return false
  end

  if description.set_version ~= nil and description.election_id ~= nil then
    if state.max_set_version ~= nil and state.max_election_id ~= nil
        and (description.set_version < state.max_set_version
          or description.set_version == state.max_set_version
            and description.election_id < state.max_election_id)
    then
      return true
    end

    state.max_election_id = description.election_id
  end

  if description.set_version ~= nil
      and (state.max_set_version == nil
        or description.set_version > state.max_set_version)
  then
    state.max_set_version = description.set_version
  end

  return false
end

local function update_from_primary(state, server)
  local description = SERVER_STATES[server]

  if state.set_name == nil then
    state.set_name = description.set_name
  elseif state.set_name ~= description.set_name then
    state.servers[description.address] = nil
    state.type = has_primary(state.servers)
    return
  end

  if stale_primary(state, server) then
    state.servers[description.address] = unknown_from(
      server,
      "primary marked stale due to electionId/setVersion mismatch"
    )
    state.type = has_primary(state.servers)
    return
  end

  for address, current in pairs(state.servers) do
    if address ~= description.address
        and SERVER_STATES[current].type == SERVER_TYPE.RS_PRIMARY
    then
      state.servers[address] = unknown_from(
        current,
        "primary marked stale due to discovery of newer primary"
      )
    end
  end

  for address in pairs(description.all_hosts) do
    if state.servers[address] == nil then
      state.servers[address] = error_server(address, "server has not been checked")
    end
  end

  for address in pairs(state.servers) do
    if not description.all_hosts[address] then
      state.servers[address] = nil
    end
  end

  state.type = has_primary(state.servers)
end

local function transition(topology, server)
  local state = copy_topology(topology)
  local description = SERVER_STATES[server]
  local address = description.address

  if state.type == TOPOLOGY_TYPE.LOAD_BALANCED
      and description.type ~= SERVER_TYPE.LOAD_BALANCER
  then
    return topology
  end

  state.servers[address] = server

  if state.type == TOPOLOGY_TYPE.LOAD_BALANCED then
    return new_topology(state)
  end

  if state.type == TOPOLOGY_TYPE.SINGLE then
    if state.set_name ~= nil and state.set_name ~= description.set_name then
      state.servers[address] = unknown_from(
        server,
        "configured replica set name does not match the server"
      )
    end

    return new_topology(state)
  end

  if state.type == TOPOLOGY_TYPE.UNKNOWN then
    if description.type == SERVER_TYPE.STANDALONE
        or description.type == SERVER_TYPE.LOAD_BALANCER
    then
      if #state.seeds == 1 then
        state.type = TOPOLOGY_TYPE.SINGLE
      else
        state.servers[address] = nil
      end
    elseif description.type == SERVER_TYPE.MONGOS then
      state.type = TOPOLOGY_TYPE.SHARDED
    elseif description.type == SERVER_TYPE.RS_PRIMARY then
      state.type = TOPOLOGY_TYPE.REPLICA_SET_WITH_PRIMARY
      update_from_primary(state, server)
    elseif MEMBER_TYPES[description.type] then
      state.type = TOPOLOGY_TYPE.REPLICA_SET_NO_PRIMARY
      update_without_primary(state, server)
    end
  elseif state.type == TOPOLOGY_TYPE.SHARDED then
    if description.type ~= SERVER_TYPE.MONGOS
        and description.type ~= SERVER_TYPE.UNKNOWN
    then
      state.servers[address] = nil
    end
  elseif state.type == TOPOLOGY_TYPE.REPLICA_SET_NO_PRIMARY then
    if description.type == SERVER_TYPE.STANDALONE
        or description.type == SERVER_TYPE.MONGOS
    then
      state.servers[address] = nil
    elseif description.type == SERVER_TYPE.RS_PRIMARY then
      state.type = TOPOLOGY_TYPE.REPLICA_SET_WITH_PRIMARY
      update_from_primary(state, server)
    elseif MEMBER_TYPES[description.type] then
      update_without_primary(state, server)
    end
  elseif state.type == TOPOLOGY_TYPE.REPLICA_SET_WITH_PRIMARY then
    if description.type == SERVER_TYPE.STANDALONE
        or description.type == SERVER_TYPE.MONGOS
    then
      state.servers[address] = nil
      state.type = has_primary(state.servers)
    elseif description.type == SERVER_TYPE.RS_PRIMARY then
      update_from_primary(state, server)
    elseif MEMBER_TYPES[description.type] then
      update_with_primary_from_member(state, server)
    else
      state.type = has_primary(state.servers)
    end
  end

  return new_topology(state)
end

local function list_equals(left, right)
  if #left ~= #right then
    return false
  end

  for index = 1, #left do
    if left[index] ~= right[index] then
      return false
    end
  end

  return true
end

local function document_equals(left, right)
  if left == nil or right == nil then
    return left == right
  end

  local left_bytes = bson.encode(left)
  local right_bytes = bson.encode(right)

  return left_bytes ~= nil and left_bytes == right_bytes
end

local function error_equals(left, right)
  if left == nil or right == nil then
    return left == right
  end

  return left.category == right.category
    and left.code == right.code
    and left.code_name == right.code_name
    and left.message == right.message
end

function SERVER_METHODS:equals(other)
  local left = SERVER_STATES[self]
  local right = SERVER_STATES[other]

  if not right or left.address ~= right.address then
    return false
  end

  for _, name in ipairs({
    "election_id",
    "last_write_date",
    "logical_session_timeout_minutes",
    "max_bson_size",
    "max_message_size",
    "max_wire_version",
    "max_write_batch_size",
    "me",
    "min_wire_version",
    "op_time",
    "primary",
    "set_name",
    "set_version",
    "type",
  }) do
    if left[name] ~= right[name] then
      return false
    end
  end

  return list_equals(left.arbiters, right.arbiters)
    and list_equals(left.hosts, right.hosts)
    and list_equals(left.passives, right.passives)
    and document_equals(left.tags, right.tags)
    and document_equals(left.topology_version, right.topology_version)
    and error_equals(left.error, right.error)
end

function TOPOLOGY_METHODS:server(address)
  local normalized = normalize_address(address)

  return normalized and TOPOLOGY_STATES[self].servers[normalized] or nil
end

function TOPOLOGY_METHODS:addresses()
  local addresses = {}

  for address in pairs(TOPOLOGY_STATES[self].servers) do
    addresses[address] = true
  end

  return list_from_set(addresses)
end

function TOPOLOGY_METHODS:closed()
  local state = copy_topology(self)

  state.servers = {}
  state.type = TOPOLOGY_TYPE.UNKNOWN
  return new_topology(state)
end

function TOPOLOGY_METHODS:update(address, response, options)
  local state = TOPOLOGY_STATES[self]
  local normalized, address_err = normalize_address(address)

  if not normalized then
    error(address_err, 2)
  end

  if state.type ~= TOPOLOGY_TYPE.SINGLE and state.servers[normalized] == nil then
    return self
  end

  options = options or {}

  if type(options) ~= "table" then
    error("SDAM update options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "error" and key ~= "generation" and key ~= "last_update_time"
        and key ~= "minimum_round_trip_time" and key ~= "round_trip_time"
    then
      error("unknown SDAM update option: " .. tostring(key), 2)
    end
  end

  local current = state.servers[normalized]
  local current_state = current and SERVER_STATES[current]
  local generation = options.generation

  if generation ~= nil and (math.type(generation) ~= "integer" or generation < 0) then
    error("generation must be a non-negative integer", 2)
  end

  if current_state and generation ~= nil and generation < current_state.generation then
    return self
  end

  local parse_options = {
    error = options.error,
    generation = generation or current_state and current_state.generation or 0,
    last_update_time = options.last_update_time,
    minimum_round_trip_time = options.minimum_round_trip_time,
    round_trip_time = options.round_trip_time,
  }
  local server = parse_server(normalized, response, parse_options)

  if current_state and topology_version_is_stale(
      current_state.topology_version,
      SERVER_STATES[server].topology_version
    )
  then
    return self
  end

  return transition(self, server)
end

function TOPOLOGY_METHODS:with_generation(address, generation)
  if math.type(generation) ~= "integer" or generation < 0 then
    error("generation must be a non-negative integer", 2)
  end

  local normalized, address_err = normalize_address(address)

  if not normalized then
    error(address_err, 2)
  end

  local state = copy_topology(self)
  local server = state.servers[normalized]

  if not server then
    error("generation address is not in the topology", 2)
  end

  if generation < SERVER_STATES[server].generation then
    error("generation cannot move backwards", 2)
  end

  state.servers[normalized] = clone_server(server, { generation = generation })
  return new_topology(state)
end

function TOPOLOGY_METHODS:with_round_trip_times(address, average, minimum)
  for name, value in pairs({ average = average, minimum = minimum }) do
    if type(value) ~= "number" or value ~= value or value < 0
        or value == math.huge
    then
      error(name .. " round trip time must be a finite non-negative number", 2)
    end
  end

  local normalized, address_err = normalize_address(address)

  if not normalized then
    error(address_err, 2)
  end

  local state = copy_topology(self)
  local server = state.servers[normalized]

  if not server then
    error("round trip time address is not in the topology", 2)
  end

  state.servers[normalized] = clone_server(server, {
    minimum_round_trip_time = minimum,
    round_trip_time = average,
  })
  return new_topology(state)
end

function TOPOLOGY_METHODS:with_srv_hosts(addresses)
  if type(addresses) ~= "table" or #addresses == 0 then
    error("SRV host reconciliation requires a non-empty address array", 2)
  end

  local source = TOPOLOGY_STATES[self]

  if source.type ~= TOPOLOGY_TYPE.UNKNOWN
      and source.type ~= TOPOLOGY_TYPE.SHARDED
  then
    return self
  end

  local normalized = {}
  local wanted = {}

  for index, value in ipairs(addresses) do
    local address, address_err = normalize_address(value)

    if not address then
      error(address_err, 2)
    end

    if not wanted[address] then
      normalized[#normalized + 1] = address
      wanted[address] = true
    end

    if index ~= math.tointeger(index) then
      error("SRV hosts must be a dense array", 2)
    end
  end

  for key in pairs(addresses) do
    if math.type(key) ~= "integer" or key < 1 or key > #addresses then
      error("SRV hosts must be a dense array", 2)
    end
  end

  local unchanged = #normalized == #self:addresses()

  if unchanged then
    for _, address in ipairs(normalized) do
      if source.servers[address] == nil then
        unchanged = false
        break
      end
    end
  end

  if unchanged then
    return self
  end

  local state = copy_topology(self)

  state.servers = {}
  state.seeds = readonly_table(normalized, "seeds")

  for _, address in ipairs(normalized) do
    state.servers[address] = source.servers[address]
      or error_server(address, "server has not been checked")
  end

  return new_topology(state)
end

function M.server_description(address, response, options)
  local normalized, address_err = normalize_address(address)

  if not normalized then
    error(address_err, 2)
  end

  return parse_server(normalized, response or bson.document({}), options)
end

function M.new(options)
  if type(options) ~= "table" then
    error("topology options must be a table", 2)
  end

  local seeds = options.seeds

  if type(seeds) ~= "table" or #seeds == 0 then
    error("topology seeds must be a non-empty array", 2)
  end

  for key in pairs(options) do
    if key ~= "client_max_wire_version" and key ~= "client_min_wire_version"
        and key ~= "seeds" and key ~= "set_name" and key ~= "type"
    then
      error("unknown topology option: " .. tostring(key), 2)
    end
  end

  local topology_type = options.type or TOPOLOGY_TYPE.UNKNOWN

  if not VALID_TOPOLOGY_TYPES[topology_type] then
    error("topology type is invalid", 2)
  end

  if options.set_name ~= nil
      and (type(options.set_name) ~= "string" or options.set_name == "")
  then
    error("set_name must be a non-empty string", 2)
  end

  if topology_type == TOPOLOGY_TYPE.SINGLE and #seeds ~= 1 then
    error("Single topology requires exactly one seed", 2)
  elseif topology_type == TOPOLOGY_TYPE.LOAD_BALANCED and #seeds ~= 1 then
    error("LoadBalanced topology requires exactly one seed", 2)
  end

  local client_min = options.client_min_wire_version or 21
  local client_max = options.client_max_wire_version or 27

  if math.type(client_min) ~= "integer" or client_min < 0 then
    error("client_min_wire_version must be a non-negative integer", 2)
  end

  if math.type(client_max) ~= "integer" or client_max < client_min then
    error("client_max_wire_version must be an integer no less than the minimum", 2)
  end

  local normalized_seeds = {}
  local servers = {}

  for index = 1, #seeds do
    local address, address_err = normalize_address(seeds[index])

    if not address then
      error(address_err, 2)
    end

    if not servers[address] then
      normalized_seeds[#normalized_seeds + 1] = address
      servers[address] = error_server(address, "server has not been checked")
    end
  end

  return new_topology({
    client_max_wire_version = client_max,
    client_min_wire_version = client_min,
    max_election_id = nil,
    max_set_version = nil,
    seeds = readonly_table(normalized_seeds, "seeds"),
    servers = servers,
    set_name = options.set_name,
    type = topology_type,
  })
end

function M.from_uri(connection_string, options)
  local parsed, err = uri_parser.parse(connection_string)

  if not parsed then
    return nil, err
  end

  local config
  config, err = driver_options.normalize(parsed.options, nil, parsed)

  if not config then
    return nil, err
  end

  local seeds = {}

  for index, host in ipairs(parsed.hosts) do
    seeds[index] = address_for_host(host)
  end

  local topology_type

  if config.load_balanced then
    topology_type = TOPOLOGY_TYPE.LOAD_BALANCED
  elseif config.direct_connection then
    topology_type = TOPOLOGY_TYPE.SINGLE
  elseif config.replica_set ~= nil then
    topology_type = TOPOLOGY_TYPE.REPLICA_SET_NO_PRIMARY
  else
    topology_type = TOPOLOGY_TYPE.UNKNOWN
  end

  options = options or {}

  if type(options) ~= "table" then
    error("topology URI options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "client_max_wire_version" and key ~= "client_min_wire_version" then
      error("unknown topology URI option: " .. tostring(key), 2)
    end
  end

  return M.new({
    client_max_wire_version = options.client_max_wire_version,
    client_min_wire_version = options.client_min_wire_version,
    seeds = seeds,
    set_name = config.replica_set,
    type = topology_type,
  })
end

return M
