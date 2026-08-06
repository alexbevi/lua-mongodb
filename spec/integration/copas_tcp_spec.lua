local copas = require("copas")
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
end)
