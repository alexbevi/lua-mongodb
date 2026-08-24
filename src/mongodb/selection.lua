local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local sdam = require("mongodb.sdam")

local M = {}

local READ_PREFERENCE_STATES = setmetatable({}, { __mode = "k" })

local MODE = {
  NEAREST = "nearest",
  PRIMARY = "primary",
  PRIMARY_PREFERRED = "primary_preferred",
  SECONDARY = "secondary",
  SECONDARY_PREFERRED = "secondary_preferred",
}

local MODE_NAMES = {
  nearest = MODE.NEAREST,
  Nearest = MODE.NEAREST,
  primary = MODE.PRIMARY,
  Primary = MODE.PRIMARY,
  primaryPreferred = MODE.PRIMARY_PREFERRED,
  PrimaryPreferred = MODE.PRIMARY_PREFERRED,
  primary_preferred = MODE.PRIMARY_PREFERRED,
  secondary = MODE.SECONDARY,
  Secondary = MODE.SECONDARY,
  secondaryPreferred = MODE.SECONDARY_PREFERRED,
  SecondaryPreferred = MODE.SECONDARY_PREFERRED,
  secondary_preferred = MODE.SECONDARY_PREFERRED,
}

local AVAILABLE_TYPES = {
  [sdam.SERVER_TYPE.LOAD_BALANCER] = true,
  [sdam.SERVER_TYPE.MONGOS] = true,
  [sdam.SERVER_TYPE.RS_ARBITER] = true,
  [sdam.SERVER_TYPE.RS_GHOST] = true,
  [sdam.SERVER_TYPE.RS_OTHER] = true,
  [sdam.SERVER_TYPE.RS_PRIMARY] = true,
  [sdam.SERVER_TYPE.RS_SECONDARY] = true,
  [sdam.SERVER_TYPE.STANDALONE] = true,
}

local READABLE_TYPES = {
  [sdam.SERVER_TYPE.RS_PRIMARY] = true,
  [sdam.SERVER_TYPE.RS_SECONDARY] = true,
}

local READ_PREFERENCE_METATABLE = {
  __index = function(value, key)
    local state = READ_PREFERENCE_STATES[value]

    return state and state[key] or nil
  end,
  __metatable = "mongodb.selection.read_preference",
  __newindex = function()
    error("read preferences are immutable", 2)
  end,
}

local function readonly_array(values, kind)
  return setmetatable({}, {
    __index = values,
    __len = function()
      return #values
    end,
    __metatable = "mongodb.selection." .. kind,
    __newindex = function()
      error(kind .. " values are immutable", 2)
    end,
    __pairs = function()
      return next, values, nil
    end,
  })
end

local function readonly_map(values, kind)
  return setmetatable({}, {
    __index = values,
    __metatable = "mongodb.selection." .. kind,
    __newindex = function()
      error(kind .. " values are immutable", 2)
    end,
    __pairs = function()
      return next, values, nil
    end,
  })
end

M.MODE = setmetatable({}, {
  __index = MODE,
  __metatable = "mongodb.selection.modes",
  __newindex = function()
    error("selection modes are immutable", 2)
  end,
  __pairs = function()
    return next, MODE, nil
  end,
})

local function config_error(message, details)
  return errors.new({
    category = errors.CATEGORY.CONFIGURATION,
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
  elseif bson.is_tagged(value, "datetime") then
    return value.milliseconds
  end
end

local function iter_document(value)
  if bson.is_document(value) then
    return value:iter()
  end

  return pairs(value)
end

local function iter_array(value)
  if bson.is_array(value) then
    return value:iter()
  end

  return ipairs(value)
end

local function copy_tag_set(value)
  if type(value) ~= "table" or getmetatable(value) ~= nil
      and not bson.is_document(value)
  then
    return nil, "each read preference tag set must be a table or BSON document"
  end

  local result = {}

  for key, item in iter_document(value) do
    if type(key) ~= "string" or key == "" or type(item) ~= "string" then
      return nil, "read preference tags must use non-empty string keys and string values"
    end

    result[key] = item
  end

  return result
end


local function copy_tag_sets(value)
  if value == nil then
    return { {} }
  end

  if type(value) ~= "table" or getmetatable(value) ~= nil
      and not bson.is_array(value)
  then
    return nil, "read preference tag_sets must be an array"
  end

  local result = {}

  for index, tag_set in iter_array(value) do
    local copy, copy_err = copy_tag_set(tag_set)

    if not copy then
      return nil, copy_err
    end

    result[index] = copy
  end

  if not bson.is_array(value) then
    for key in pairs(value) do
      if math.type(key) ~= "integer" or key < 1 or key > #value then
        return nil, "read preference tag_sets must be a dense array"
      end
    end
  end

  return result
end

local function has_non_empty_tag_set(tag_sets)
  for _, tag_set in ipairs(tag_sets) do
    if next(tag_set) ~= nil then
      return true
    end
  end

  return false
end

local function new_read_preference(state)
  local value = {}
  local tag_sets = {}

  for index, tag_set in ipairs(state.tag_sets) do
    tag_sets[index] = readonly_map(tag_set, "tag_set")
  end

  state.tag_sets = readonly_array(tag_sets, "tag_sets")
  READ_PREFERENCE_STATES[value] = state
  return setmetatable(value, READ_PREFERENCE_METATABLE)
end

function M.read_preference(options)
  if READ_PREFERENCE_STATES[options] then
    return options
  end

  options = options or {}

  if type(options) ~= "table" then
    return nil, config_error("read preference must be a table")
  end

  local function option_iterator()
    if bson.is_document(options) then
      return options:iter()
    end

    return pairs(options)
  end

  for key in option_iterator() do
    if key ~= "maxStalenessSeconds" and key ~= "max_staleness_seconds"
        and key ~= "mode" and key ~= "tag_sets" and key ~= "tags"
    then
      return nil, config_error("unknown read preference option: " .. tostring(key))
    end
  end

  local function option(name)
    if bson.is_document(options) then
      return options:get(name)
    end

    return options[name]
  end

  local mode_name = option("mode")

  if bson.is_null(mode_name) then
    mode_name = nil
  end

  local mode = MODE_NAMES[mode_name or MODE.PRIMARY]

  if mode == nil then
    return nil, config_error("unsupported read preference mode")
  end

  local tag_sets, tag_err = copy_tag_sets(option("tag_sets") or option("tags"))

  if not tag_sets then
    return nil, config_error(tag_err)
  end

  local max_staleness = option("max_staleness_seconds")

  if max_staleness == nil then
    max_staleness = option("maxStalenessSeconds")
  end

  if max_staleness == nil or bson.is_null(max_staleness) then
    max_staleness = -1
  else
    max_staleness = number_value(max_staleness)
  end

  if math.type(max_staleness) ~= "integer"
      or max_staleness ~= -1 and max_staleness <= 0
  then
    return nil, config_error("maxStalenessSeconds must be a positive integer or -1")
  end

  if mode == MODE.PRIMARY and max_staleness ~= -1 then
    return nil, config_error("primary read preference cannot use max staleness")
  end

  if mode == MODE.PRIMARY and has_non_empty_tag_set(tag_sets) then
    return nil, config_error("primary read preference cannot use tag sets")
  end

  return new_read_preference({
    max_staleness_seconds = max_staleness,
    mode = mode,
    tag_sets = tag_sets,
  })
end

local function known_servers(topology)
  local result = {}

  for _, address in ipairs(topology:addresses()) do
    local server = topology:server(address)

    if AVAILABLE_TYPES[server.type] then
      result[#result + 1] = server
    end
  end

  return result
end

local function filter_type(servers, server_type)
  local result = {}

  for _, server in ipairs(servers) do
    if server.type == server_type then
      result[#result + 1] = server
    end
  end

  return result
end

local function filter_readable(servers)
  local result = {}

  for _, server in ipairs(servers) do
    if READABLE_TYPES[server.type] then
      result[#result + 1] = server
    end
  end

  return result
end

local function primary(servers)
  local values = filter_type(servers, sdam.SERVER_TYPE.RS_PRIMARY)

  return values[1]
end

local function validate_staleness(read_preference, topology, heartbeat_frequency_ms)
  local max_staleness = read_preference.max_staleness_seconds

  if max_staleness == -1
      or topology.type ~= sdam.TOPOLOGY_TYPE.REPLICA_SET_WITH_PRIMARY
        and topology.type ~= sdam.TOPOLOGY_TYPE.REPLICA_SET_NO_PRIMARY
  then
    return true
  end

  if max_staleness < 90 then
    return nil, config_error(
      "maxStalenessSeconds must be at least 90",
      { max_staleness_seconds = max_staleness }
    )
  end

  if max_staleness * 1000 < heartbeat_frequency_ms + 10000 then
    return nil, config_error(
      "maxStalenessSeconds must be at least heartbeatFrequencyMS plus 10 seconds",
      {
        heartbeat_frequency_ms = heartbeat_frequency_ms,
        max_staleness_seconds = max_staleness,
      }
    )
  end

  return true
end

local function last_write_ms(server)
  return number_value(server.last_write_date)
end

local function staleness_filter(servers, all_servers, preference, heartbeat_ms)
  local max_staleness_ms = preference.max_staleness_seconds * 1000

  if max_staleness_ms < 0 then
    return servers
  end

  local reference_primary = primary(all_servers)
  local max_last_write

  if not reference_primary then
    for _, server in ipairs(all_servers) do
      if server.type == sdam.SERVER_TYPE.RS_SECONDARY then
        local last_write = last_write_ms(server)

        if last_write ~= nil and (max_last_write == nil or last_write > max_last_write) then
          max_last_write = last_write
        end
      end
    end
  end

  local result = {}

  for _, server in ipairs(servers) do
    if server.type ~= sdam.SERVER_TYPE.RS_SECONDARY then
      result[#result + 1] = server
    else
      local last_write = last_write_ms(server)
      local stale

      if reference_primary then
        local primary_last_write = last_write_ms(reference_primary)
        local server_update = number_value(server.last_update_time)
        local primary_update = number_value(reference_primary.last_update_time)

        if last_write ~= nil and primary_last_write ~= nil
            and server_update ~= nil and primary_update ~= nil
        then
          stale = (server_update - last_write)
            - (primary_update - primary_last_write) + heartbeat_ms
        end
      elseif last_write ~= nil and max_last_write ~= nil then
        stale = max_last_write - last_write + heartbeat_ms
      end

      if stale ~= nil and stale <= max_staleness_ms then
        result[#result + 1] = server
      end
    end
  end

  return result
end

local function tag_matches(server, tag_set)
  for key, expected in pairs(tag_set) do
    if server.tags:get(key) ~= expected then
      return false
    end
  end

  return true
end

local function tag_filter(servers, tag_sets)
  if #tag_sets == 0 then
    return servers
  end

  for _, tag_set in ipairs(tag_sets) do
    local result = {}

    for _, server in ipairs(servers) do
      if tag_matches(server, tag_set) then
        result[#result + 1] = server
      end
    end

    if #result > 0 then
      return result
    end
  end

  return {}
end

local function read_candidates(servers, all_servers, preference, heartbeat_ms)
  local mode = preference.mode

  if mode == MODE.PRIMARY then
    local value = primary(servers)

    return value and { value } or {}
  end

  if mode == MODE.PRIMARY_PREFERRED then
    local value = primary(servers)

    if value then
      return { value }
    end

    local secondaries = filter_type(servers, sdam.SERVER_TYPE.RS_SECONDARY)

    secondaries = staleness_filter(
      secondaries,
      all_servers,
      preference,
      heartbeat_ms
    )
    return tag_filter(secondaries, preference.tag_sets)
  end

  if mode == MODE.SECONDARY or mode == MODE.SECONDARY_PREFERRED then
    local secondaries = filter_type(servers, sdam.SERVER_TYPE.RS_SECONDARY)

    secondaries = staleness_filter(
      secondaries,
      all_servers,
      preference,
      heartbeat_ms
    )
    secondaries = tag_filter(secondaries, preference.tag_sets)

    if #secondaries > 0 or mode == MODE.SECONDARY then
      return secondaries
    end

    local value = primary(servers)

    return value and { value } or {}
  end

  local members = filter_readable(servers)

  members = staleness_filter(members, all_servers, preference, heartbeat_ms)
  return tag_filter(members, preference.tag_sets)
end

local function topology_candidates(topology, operation, servers, preference, heartbeat_ms)
  if topology.type == sdam.TOPOLOGY_TYPE.UNKNOWN then
    return {}
  elseif topology.type == sdam.TOPOLOGY_TYPE.SINGLE
      or topology.type == sdam.TOPOLOGY_TYPE.LOAD_BALANCED
  then
    return servers
  elseif topology.type == sdam.TOPOLOGY_TYPE.SHARDED then
    return filter_type(servers, sdam.SERVER_TYPE.MONGOS)
  elseif operation == "write" then
    local value = primary(servers)

    return value and { value } or {}
  end

  return read_candidates(servers, servers, preference, heartbeat_ms)
end

local function address_from_deprioritized(value)
  if type(value) == "string" then
    return value:lower()
  elseif bson.is_document(value) then
    local address = value:get("address")

    return type(address) == "string" and address:lower() or nil
  elseif type(value) == "table" then
    return type(value.address) == "string" and value.address:lower() or nil
  end
end

local function deprioritized_set(values)
  local result = {}

  if values == nil then
    return result
  end

  if type(values) ~= "table" then
    error("deprioritized_servers must be an array", 3)
  end

  for _, value in iter_array(values) do
    local address = address_from_deprioritized(value)

    if not address then
      error("deprioritized server must provide an address", 3)
    end

    if not address:find(":", 1, true) then
      address = address .. ":27017"
    end

    result[address] = true
  end

  return result
end

local function without_deprioritized(servers, deprioritized)
  local result = {}

  for _, server in ipairs(servers) do
    if not deprioritized[server.address] then
      result[#result + 1] = server
    end
  end

  return result
end

local function validate_options(options)
  options = options or {}

  if type(options) ~= "table" then
    error("selection options must be a table", 3)
  end

  for key in pairs(options) do
    if key ~= "deprioritized_servers" and key ~= "heartbeat_frequency_ms"
        and key ~= "local_threshold_ms" and key ~= "operation_counts"
        and key ~= "random"
        and key ~= "selector" and key ~= "timeout_ms"
    then
      error("unknown selection option: " .. tostring(key), 3)
    end
  end

  local heartbeat = options.heartbeat_frequency_ms or 10000
  local threshold = options.local_threshold_ms or 15
  local timeout = options.timeout_ms or 30000

  if math.type(heartbeat) ~= "integer" or heartbeat < 500 then
    error("heartbeat_frequency_ms must be an integer of at least 500", 3)
  end

  if type(threshold) ~= "number" or threshold < 0 then
    error("local_threshold_ms must be a non-negative number", 3)
  end

  if type(timeout) ~= "number" or timeout < 0 then
    error("timeout_ms must be a non-negative number", 3)
  end

  if options.selector ~= nil and type(options.selector) ~= "function" then
    error("selector must be a function", 3)
  end

  if options.random ~= nil and type(options.random) ~= "function" then
    error("random must be a function", 3)
  end

  if options.operation_counts ~= nil and type(options.operation_counts) ~= "table" then
    error("operation_counts must be a table", 3)
  end

  return options, heartbeat, threshold, timeout
end

local function apply_custom_selector(servers, selector)
  if not selector or #servers == 0 then
    return servers
  end

  local selected = selector(readonly_array(servers, "selector_input"))

  if type(selected) ~= "table" then
    error("custom selector must return an array", 3)
  end

  local allowed = {}

  for _, server in ipairs(servers) do
    allowed[server] = true
  end

  local result = {}

  for index = 1, #selected do
    if not allowed[selected[index]] then
      error("custom selector returned a server outside its input", 3)
    end

    result[index] = selected[index]
  end

  for key in pairs(selected) do
    if math.type(key) ~= "integer" or key < 1 or key > #selected then
      error("custom selector must return a dense array", 3)
    end
  end

  return result
end

local function latency_window(servers, threshold)
  if #servers == 0 then
    return {}
  end

  local fastest

  for _, server in ipairs(servers) do
    if type(server.round_trip_time) ~= "number" or server.round_trip_time < 0 then
      return nil, config_error(
        "round trip time is unavailable for server " .. server.address,
        { address = server.address }
      )
    end

    if fastest == nil or server.round_trip_time < fastest then
      fastest = server.round_trip_time
    end
  end

  local result = {}

  for _, server in ipairs(servers) do
    if server.round_trip_time <= fastest + threshold then
      result[#result + 1] = server
    end
  end

  return result
end

local function selection_result(suitable, in_window)
  local state = {
    in_latency_window = readonly_array(in_window, "latency_window"),
    suitable_servers = readonly_array(suitable, "suitable_servers"),
  }

  return setmetatable({}, {
    __index = state,
    __metatable = "mongodb.selection.result",
    __newindex = function()
      error("selection results are immutable", 2)
    end,
  })
end

function M.evaluate(topology, operation, preference, options)
  if getmetatable(topology) ~= "mongodb.sdam.topology_description" then
    error("selection requires an SDAM topology description", 2)
  end

  if operation ~= "read" and operation ~= "write" then
    error("selection operation must be read or write", 2)
  end

  local normalized, preference_err = M.read_preference(preference)

  if not normalized then
    return nil, preference_err
  end

  local heartbeat
  local threshold

  options, heartbeat, threshold = validate_options(options)

  if topology.compatible == false then
    return nil, config_error(topology.compatibility_error or "topology is incompatible")
  end

  local valid, staleness_err = validate_staleness(normalized, topology, heartbeat)

  if not valid then
    return nil, staleness_err
  end

  local all_servers = known_servers(topology)

  if topology.type == sdam.TOPOLOGY_TYPE.LOAD_BALANCED then
    return selection_result(all_servers, all_servers)
  end

  local deprioritized = deprioritized_set(options.deprioritized_servers)
  local preferred = without_deprioritized(all_servers, deprioritized)
  local suitable = topology_candidates(
    topology,
    operation,
    preferred,
    normalized,
    heartbeat
  )

  if #suitable == 0 and next(deprioritized) ~= nil then
    suitable = topology_candidates(
      topology,
      operation,
      all_servers,
      normalized,
      heartbeat
    )
  end

  suitable = apply_custom_selector(suitable, options.selector)
  local in_window, window_err = latency_window(suitable, threshold)

  if not in_window then
    return nil, window_err
  end

  return selection_result(suitable, in_window)
end

function M.candidates(topology, operation, preference, options)
  local result, err = M.evaluate(topology, operation, preference, options)

  return result and result.in_latency_window or nil, err
end

function M.average_rtt(previous_ms, sample_ms)
  if previous_ms ~= nil and (type(previous_ms) ~= "number" or previous_ms < 0) then
    error("previous RTT must be a non-negative number or nil", 2)
  end

  if type(sample_ms) ~= "number" or sample_ms < 0 then
    error("RTT sample must be a non-negative number", 2)
  end

  if previous_ms == nil then
    return sample_ms
  end

  return 0.2 * sample_ms + 0.8 * previous_ms
end


local function operation_count(operation_counts, server)
  local count = operation_counts[server]

  if count == nil then
    count = operation_counts[server.address] or 0
  end

  if math.type(count) ~= "integer" or count < 0 then
    error("operation counts must be non-negative integers", 3)
  end

  return count
end

function M.choose(candidates, options)
  if type(candidates) ~= "table" then
    error("selection candidates must be an array", 2)
  end

  if #candidates == 0 then
    return nil
  elseif #candidates == 1 then
    return candidates[1]
  end

  options = options or {}

  if type(options) ~= "table" then
    error("choice options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "operation_counts" and key ~= "random" then
      error("unknown choice option: " .. tostring(key), 2)
    end
  end

  if options.random ~= nil and type(options.random) ~= "function" then
    error("random must be a function", 2)
  end

  if options.operation_counts ~= nil and type(options.operation_counts) ~= "table" then
    error("operation_counts must be a table", 2)
  end

  local random = options.random or math.random
  local operation_counts = options.operation_counts or {}
  local first_index = random(#candidates)
  local second_index = random(#candidates - 1)

  if math.type(first_index) ~= "integer"
      or first_index < 1 or first_index > #candidates
      or math.type(second_index) ~= "integer"
      or second_index < 1 or second_index >= #candidates
  then
    error("random selector returned an out-of-range index", 2)
  end

  if second_index >= first_index then
    second_index = second_index + 1
  end

  local first = candidates[first_index]
  local second = candidates[second_index]

  if operation_count(operation_counts, first) <= operation_count(operation_counts, second) then
    return first
  end

  return second
end

local function topology_summary(topology)
  local servers = {}

  for _, address in ipairs(topology:addresses()) do
    local server = topology:server(address)
    local description = address .. "=" .. server.type

    if server.error then
      description = description .. "(" .. server.error.message .. ")"
    end

    servers[#servers + 1] = description
  end

  return topology.type .. "{" .. table.concat(servers, ", ") .. "}"
end

function M.select(topology, operation, preference, options)
  local result, err = M.evaluate(topology, operation, preference, options)

  if not result then
    return nil, err
  end

  local candidates = result.in_latency_window

  if #candidates == 0 then
    local normalized = assert(M.read_preference(preference))
    local _, _, _, timeout = validate_options(options)
    local summary = topology_summary(topology)

    return nil, errors.new({
      category = errors.CATEGORY.SERVER_SELECTION,
      details = {
        operation = operation,
        read_preference_mode = normalized.mode,
        timeout_ms = timeout,
      },
      message = string.format(
        "server selection timed out after %sms for %s with %s; final topology: %s",
        tostring(timeout),
        operation,
        normalized.mode,
        summary
      ),
      timeout = true,
      topology = summary,
    })
  end

  return M.choose(candidates, {
    operation_counts = options and options.operation_counts,
    random = options and options.random,
  })
end

return M
