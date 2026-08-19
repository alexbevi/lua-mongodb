local bridge = require("bridge")

local role = arg[1]

if role ~= "p1" and role ~= "p2" then
  io.stderr:write("Usage: lua run_bridge.lua p1|p2\n")
  os.exit(2)
end

local default_port = role == "p1" and 27101 or 27102
local options = {
  role = role,
  udp_port = tonumber(os.getenv("PONG_UDP_PORT")) or default_port,
  match_id = os.getenv("PONG_MATCH_ID") or "demo-match",
  uri = os.getenv("MONGODB_URI")
    or "mongodb://127.0.0.1:27020/pong_demo?replicaSet=rs0",
}

local ok, err = bridge.run(options)

if not ok then
  io.stderr:write("Pong bridge failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
