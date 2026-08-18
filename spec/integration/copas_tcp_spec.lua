local copas = require("copas")
local errors = require("mongodb.error")
local runtime = require("mongodb.runtime")
local socket = require("socket")
local transport = require("mongodb.network.transport")

describe("Copas TCP runtime adapter", function()
  it("exchanges exact partial data over a loopback socket", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    port = assert(math.tointeger(port))
    local outcome

    copas.addserver(server, function(client)
      client = copas.wrap(client)
      local request = assert(client:receive(5))

      assert.are.equal("hello", request)
      assert(client:send("w"))
      assert(client:send("orld"))
      client:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local adapter = runtime.copas()
        local connection = assert(transport.connect(adapter, "127.0.0.1", port, {
          deadline = runtime.deadline_after(adapter, 2),
        }))

        assert.is_true(connection:write_all("hello"))
        assert.are.equal("world", assert(connection:read_exact(5)))
        assert.is_true(connection:close())
      end))
      copas.removeserver(server)
    end)

    assert.is_table(outcome)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("cancels a blocked loopback read", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(client)
      client = copas.wrap(client)
      assert.are.equal("hello", assert(client:receive(5)))
      copas.pause(0.05)
      client:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local adapter = runtime.copas({ lock_poll_interval = 0.001 })
        local cancellation = adapter.cancellation:new()
        local connection = assert(transport.connect(adapter, "127.0.0.1", port, {
          deadline = runtime.deadline_after(adapter, 2),
        }))

        assert.is_true(connection:write_all("hello"))
        local read = adapter.task:spawn(function()
          return connection:read_exact(1, nil, cancellation)
        end)

        adapter.clock:sleep(0.005)
        assert.is_true(cancellation:cancel("stop loopback read"))
        local value, err = adapter.task:await(read)

        assert.is_nil(value)
        assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))
        assert.are.equal("stop loopback read", err.message)
        assert.is_true(connection:close())
      end))
      copas.removeserver(server)
    end)

    assert.is_table(outcome)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
