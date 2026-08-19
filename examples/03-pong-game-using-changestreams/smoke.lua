local mongodb = require("mongodb")
local socket = require("socket")
local bridge = require("bridge")
local protocol = require("client.protocol")

local function run_smoke()
  local uri = os.getenv("MONGODB_URI")
    or "mongodb://127.0.0.1:27020/pong_demo?replicaSet=rs0"

  return mongodb.run(function()
    local client, err = mongodb.client(uri, { app_name = "pong-headless-smoke" })

    if not client then
      return nil, err
    end

    local collection = client:database():collection("matches")
    local stream
    stream, err = bridge.watch_match(collection, "demo-match")

    if not stream then
      client:close()
      return nil, err
    end

    local receiver = assert(socket.udp())
    assert(receiver:setsockname("127.0.0.1", 0))
    receiver:settimeout(1)
    local host, port = receiver:getsockname()
    local sender = assert(socket.udp())
    local payload = protocol.encode_input({
      seq = 7,
      paddle_y = 310,
      ball_x = 999,
      ball_y = 999,
      ball_vx = 999,
      ball_vy = 999,
      score_p1 = 99,
      score_p2 = 99,
    })

    assert(sender:sendto(payload, host, port))
    local received = assert(receiver:receivefrom())
    local input = assert(protocol.decode_input(received))
    local updated, paths = bridge.apply_input(collection, "demo-match", "p2", input)

    if not updated then
      receiver:close()
      sender:close()
      stream:close()
      client:close()
      return nil, paths
    end

    local change
    change, err = stream:next()

    if not change then
      receiver:close()
      sender:close()
      stream:close()
      client:close()
      return nil, err
    end

    local resume_token = stream:resume_token()
    local snapshot = bridge.snapshot_from_change(change, 1, resume_token)
    local operation_type = change:get("operationType")
    local has_full_document = change:get("fullDocument") ~= nil

    receiver:close()
    sender:close()
    stream:close()
    local closed
    closed, err = client:close()

    if not closed then
      return nil, err
    end

    print("UDP input: p2 seq=" .. input.seq .. " paddle_y=" .. input.paddle_y)
    print("MongoDB update paths: " .. table.concat(paths, ", "))
    print("Change stream: " .. operation_type .. " with "
      .. (has_full_document and "fullDocument" or "no fullDocument"))
    print(string.format(
      "Snapshot: left=%g right=%g ball=(%g,%g) score=%g-%g",
      snapshot.p1_y,
      snapshot.p2_y,
      snapshot.ball_x,
      snapshot.ball_y,
      snapshot.score_p1,
      snapshot.score_p2
    ))
    print("Resume token: " .. (resume_token and "available" or "missing"))
    return true
  end)
end

local ok, err = run_smoke()

if not ok then
  io.stderr:write("Pong smoke failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
