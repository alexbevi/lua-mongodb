local copas = require("copas")
local errors = require("mongodb.error")
local runtime = require("mongodb.runtime")
local socket = require("socket")

local function run_copas(callback)
  local outcome

  local thread = copas.addthread(function()
    outcome = table.pack(pcall(callback))
  end)

  while outcome == nil do
    copas.step()
  end

  copas.removethread(thread)

  assert.is_table(outcome)

  if not outcome[1] then
    error(outcome[2], 0)
  end

  return table.unpack(outcome, 2, outcome.n)
end

local function encode_name(name)
  local labels = {}

  for label in name:gmatch("[^.]+") do
    labels[#labels + 1] = string.char(#label) .. label
  end

  return table.concat(labels) .. "\0"
end

local function response(query, options)
  options = options or {}
  local flags = options.flags or 0x8180
  local answers = options.answers or {}
  local header = query:sub(1, 2)
    .. string.pack(">I2I2I2I2I2", flags, 1, #answers, 0, 0)
  local question = query:sub(13)

  return header .. question .. table.concat(answers)
end

local function answer(record_type, ttl, data)
  return "\192\12" .. string.pack(">I2I2I4I2", record_type, 1, ttl, #data) .. data
end

local function srv_answer(target, port, ttl)
  return answer(33, ttl, string.pack(">I2I2I2", 0, 5, port) .. encode_name(target))
end

local function txt_answer(strings, ttl)
  local data = {}

  for index, value in ipairs(strings) do
    data[index] = string.char(#value) .. value
  end

  return answer(16, ttl, table.concat(data))
end

local function with_dns_server(responder, callback)
  local server = assert(socket.udp())

  assert(server:setsockname("127.0.0.1", 0))
  local _, port = assert(server:getsockname())

  port = assert(math.tointeger(tonumber(port)))

  copas.addserver(server, function(peer)
    while true do
      local query, host, client_port = copas.receivefrom(peer)

      if query == nil then
        return
      end

      local reply = responder(query)

      if reply ~= nil then
        assert(peer:sendto(reply, host, client_port))
      end
    end
  end)

  local outcome = table.pack(pcall(callback, port))

  copas.removeserver(server)

  if not outcome[1] then
    error(outcome[2], 0)
  end

  return table.unpack(outcome, 2, outcome.n)
end

local function new_runtime(port, options)
  options = options or {}
  local entropy = options.entropy or string.rep("\18\52", 8)

  return runtime.copas({
    dns_nameservers = { { host = "127.0.0.1", port = port } },
    dns_query_timeout = options.query_timeout or 0.05,
    entropy = {
      bytes = function(_, count)
        local value = entropy:sub(1, count)

        assert.are.equal(count, #value)
        entropy = entropy:sub(count + 1)
        return value
      end,
    },
    lock_poll_interval = 0.001,
  })
end

local function with_truncated_dns_server(callback)
  local udp_server = assert(socket.udp())

  assert(udp_server:setsockname("127.0.0.1", 0))
  local _, port = assert(udp_server:getsockname())

  port = assert(math.tointeger(tonumber(port)))

  local tcp_server = assert(socket.bind("127.0.0.1", port))

  copas.addserver(udp_server, function(peer)
    local query, host, client_port = assert(copas.receivefrom(peer))

    assert(peer:sendto(response(query, { flags = 0x8380 }), host, client_port))
  end)
  copas.addserver(tcp_server, function(peer)
    peer = copas.wrap(peer)
    peer:settimeout(2)

    local size_bytes, reason, partial = peer:receive(2)

    size_bytes = size_bytes or partial

    if size_bytes == nil or #size_bytes ~= 2 then
      return nil, reason
    end

    local size = string.unpack(">I2", size_bytes)
    local query

    query, reason, partial = peer:receive(size)
    query = query or partial

    if query == nil or #query ~= size then
      return nil, reason
    end

    local reply = response(query, {
      answers = { srv_answer("tcp.example.com", 27019, 30) },
    })

    return peer:send(string.pack(">I2", #reply) .. reply)
  end)

  local outcome = table.pack(pcall(callback, port))

  copas.removeserver(udp_server)
  copas.removeserver(tcp_server)

  if not outcome[1] then
    error(outcome[2], 0)
  end

  return table.unpack(outcome, 2, outcome.n)
end

describe("Copas DNS runtime adapter", function()
  it("normalizes SRV TTLs and ordered TXT strings", function()
    run_copas(function()
      with_dns_server(function(query)
        local record_type = string.unpack(">I2", query, #query - 3)

        if record_type == 33 then
          return response(query, {
            answers = { srv_answer("db.example.com", 27018, 60) },
          })
        end

        return response(query, {
          answers = { txt_answer({ "replicaSet=", "rs0" }, 120) },
        })
      end, function(port)
        local adapter = new_runtime(port)

        assert.are.same({
          {
            port = 27018,
            priority = 0,
            target = "db.example.com",
            ttl = 60,
            weight = 5,
          },
        }, assert(adapter.dns:resolve_srv("_mongodb._tcp.example.com")))
        assert.are.same({
          { strings = { "replicaSet=", "rs0" }, ttl = 120 },
        }, assert(adapter.dns:resolve_txt("example.com")))
      end)
    end)
  end)

  it("distinguishes absence from malformed responses", function()
    run_copas(function()
      local query_count = 0

      with_dns_server(function(query)
        query_count = query_count + 1

        if query_count == 1 then
          return response(query, { flags = 0x8183 })
        end

        return query:sub(1, 2) .. string.pack(">I2I2I2I2I2", 0x8180, 1, 0, 0, 0)
      end, function(port)
        local adapter = new_runtime(port)

        assert.are.same({}, assert(adapter.dns:resolve_txt("missing.example.com")))

        local records, err = adapter.dns:resolve_srv("_mongodb._tcp.example.com")

        assert.is_nil(records)
        assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
        assert.matches("malformed DNS response", err.message, 1, true)
      end)
    end)
  end)

  it("retries truncated UDP answers over TCP", function()
    run_copas(function()
      with_truncated_dns_server(function(port)
        local adapter = new_runtime(port, { query_timeout = 1 })

        assert.are.same({
          {
            port = 27019,
            priority = 0,
            target = "tcp.example.com",
            ttl = 30,
            weight = 5,
          },
        }, assert(adapter.dns:resolve_srv("_mongodb._tcp.example.com")))
      end)
    end)
  end)

  it("applies deadlines and cancellation without blocking the Copas loop", function()
    run_copas(function()
      with_dns_server(function()
        return nil
      end, function(port)
        local adapter = new_runtime(port, { query_timeout = 0.02 })
        local records, err = adapter.dns:resolve_srv(
          "_mongodb._tcp.example.com",
          runtime.deadline_after(adapter, 0.003)
        )

        assert.is_nil(records)
        assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))

        local token = adapter.cancellation:new()
        local lookup = adapter.task:spawn(function()
          return adapter.dns:resolve_txt("example.com", nil, token)
        end)

        adapter.task:spawn(function()
          adapter.clock:sleep(0.002)
          token:cancel("stop DNS lookup")
        end)

        records, err = adapter.task:await(lookup)

        assert.is_nil(records)
        assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))
        assert.are.equal("stop DNS lookup", err.message)
      end)
    end)
  end)
end)
