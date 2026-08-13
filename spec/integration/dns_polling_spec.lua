local copas = require("copas")
local fake_runtime = require("mongodb.runtime.fake")
local runtime_module = require("mongodb.runtime")
local topology = require("mongodb.topology")

local function run_copas(callback)
  local outcome

  copas.loop(function()
    outcome = table.pack(pcall(callback))
  end)

  if not outcome[1] then
    error(outcome[2], 0)
  end
end

describe("SRV polling lifecycle", function()
  it("reconciles pools and cancels the sleeping poller on close", function()
    run_copas(function()
      local dns = fake_runtime.new()
      local runtime = runtime_module.copas({
        dns = dns.dns,
        lock_poll_interval = 0.001,
      })
      local sleep = runtime.clock.sleep
      local pools = {}

      runtime.clock.sleep = function(clock, duration, cancellation)
        if duration >= 60 then
          duration = 0.01
        end

        return sleep(clock, duration, cancellation)
      end

      dns:queue_dns("srv", {
        { port = 27017, target = "a.example.com", ttl = 120 },
        { port = 27018, target = "c.example.com", ttl = 120 },
      })
      local manager = topology.new({
        check = function()
          return nil
        end,
        pool_factory = function(address)
          local value = { address = address, closed = 0, generation = 0 }

          function value:clear()
            self.generation = self.generation + 1
            return true
          end

          function value:close()
            self.closed = self.closed + 1
            return true
          end

          function value.ready()
            return true
          end

          pools[address] = value
          return value
        end,
        runtime = runtime,
        seeds = { "a.example.com:27017", "b.example.com:27017" },
        srv = {
          hostname = "cluster.example.com",
          max_hosts = 0,
          minimum_ttl = 0,
          service_name = "mongodb",
        },
        type = "Sharded",
      })

      assert(manager:open())
      local unchanged = pools["a.example.com:27017"]
      local deadline = runtime_module.deadline_after(runtime, 1)

      while #dns.calls.dns == 0 do
        assert.is_true(runtime.clock:now() < deadline)
        assert(runtime.clock:sleep(0.001))
      end

      assert.are.equal(unchanged, pools["a.example.com:27017"])
      assert.are.equal(1, pools["b.example.com:27017"].closed)
      assert.is_table(pools["c.example.com:27018"])

      assert(manager:close())
      assert.are.equal(1, unchanged.closed)
      assert.are.equal(1, pools["c.example.com:27018"].closed)
    end)
  end)
end)
