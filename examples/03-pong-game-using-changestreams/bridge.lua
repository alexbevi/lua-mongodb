local mongodb = require("mongodb")
local socket = require("socket")
local copas = require("copas")
local protocol = require("client.protocol")

local bson = mongodb.bson
local doc = bson.document
local array = bson.array
local M = {}

local ROLE_PATHS = {
  p1 = {
    "players.p1.paddle_y",
    "players.p1.input_seq",
    "ball.x",
    "ball.y",
    "ball.vx",
    "ball.vy",
    "score.p1",
    "score.p2",
  },
  p2 = {
    "players.p2.paddle_y",
    "players.p2.input_seq",
  },
}

local function number(value)
  if type(value) == "number" then
    return value
  end

  return value:to_number()
end

local function set_fields(role, input)
  if role == "p1" then
    return doc({
      { "players.p1.paddle_y", input.paddle_y },
      { "players.p1.input_seq", input.seq },
      { "ball.x", input.ball_x },
      { "ball.y", input.ball_y },
      { "ball.vx", input.ball_vx },
      { "ball.vy", input.ball_vy },
      { "score.p1", input.score_p1 },
      { "score.p2", input.score_p2 },
    })
  end

  if role == "p2" then
    return doc({
      { "players.p2.paddle_y", input.paddle_y },
      { "players.p2.input_seq", input.seq },
    })
  end

  error("Pong bridge role must be p1 or p2", 2)
end

function M.owned_paths(role)
  local paths = ROLE_PATHS[role]

  if not paths then
    error("Pong bridge role must be p1 or p2", 2)
  end

  local copied = {}

  for index, path in ipairs(paths) do
    copied[index] = path
  end

  return copied
end

function M.apply_input(collection, match_id, role, input)
  local updated, err = collection:update_one(
    doc({ { "_id", match_id } }),
    doc({ { "$set", set_fields(role, input) } })
  )

  if not updated then
    return nil, err
  end

  if updated.matched_count ~= 1 then
    return nil, mongodb.error.new({
      category = mongodb.error.CATEGORY.WRITE,
      message = "Pong match is missing",
    })
  end

  return updated, M.owned_paths(role)
end

function M.watch_match(collection, match_id)
  return collection:watch(array({
    doc({ { "$match", doc({
      { "operationType", "update" },
      { "documentKey._id", match_id },
    }) } }),
  }), {
    full_document = "updateLookup",
    max_await_time_ms = 250,
  })
end

function M.snapshot_from_change(change, seq, resume_token)
  local full_document = change:get("fullDocument")
  local players = full_document:get("players")
  local p1 = players:get("p1")
  local p2 = players:get("p2")
  local ball = full_document:get("ball")
  local score = full_document:get("score")

  return {
    seq = seq,
    p1_y = number(p1:get("paddle_y")),
    p2_y = number(p2:get("paddle_y")),
    ball_x = number(ball:get("x")),
    ball_y = number(ball:get("y")),
    ball_vx = number(ball:get("vx")),
    ball_vy = number(ball:get("vy")),
    score_p1 = number(score:get("p1")),
    score_p2 = number(score:get("p2")),
    event_count = seq,
    resume_token = resume_token ~= nil,
  }
end

local function close_resources(stream, udp, client)
  if stream and not stream:is_closed() then
    stream:close()
  end

  if udp then
    udp:close()
  end

  if client then
    client:close()
  end
end

function M.run(options)
  return mongodb.run(function()
    local client, err = mongodb.client(options.uri, {
      app_name = "pong-bridge-" .. options.role,
    })

    if not client then
      return nil, err
    end

    local collection = client:database():collection("matches")
    local stream
    stream, err = M.watch_match(collection, options.match_id)

    if not stream then
      client:close()
      return nil, err
    end

    local udp
    udp, err = socket.udp()

    if not udp then
      close_resources(stream, nil, client)
      return nil, err
    end

    local bound
    bound, err = udp:setsockname("127.0.0.1", options.udp_port)

    if not bound then
      close_resources(stream, udp, client)
      return nil, err
    end

    udp:settimeout(0)
    local peer_host
    local peer_port
    local event_count = 0

    print("Pong bridge " .. options.role .. " listening on UDP "
      .. options.udp_port)

    while true do
      local payload, host, port = udp:receivefrom()

      if payload then
        local input, decode_err = protocol.decode_input(payload)

        if not input then
          close_resources(stream, udp, client)
          return nil, mongodb.error.new({
            category = mongodb.error.CATEGORY.PROTOCOL,
            message = decode_err,
          })
        end

        local updated
        updated, err = M.apply_input(
          collection,
          options.match_id,
          options.role,
          input
        )

        if not updated then
          close_resources(stream, udp, client)
          return nil, err
        end

        peer_host = host
        peer_port = port
      end

      local change
      change, err = stream:try_next()

      if err then
        close_resources(stream, udp, client)
        return nil, err
      end

      if change then
        event_count = event_count + 1

        if peer_host then
          local snapshot = M.snapshot_from_change(
            change,
            event_count,
            stream:resume_token()
          )
          udp:sendto(protocol.encode_snapshot(snapshot), peer_host, peer_port)
        end
      else
        copas.pause(0.01)
      end
    end
  end)
end

return M
