local M = {}

local WIDTH = 800
local HEIGHT = 600
local ARENA_TOP = 112
local ARENA_BOTTOM = 548
local PADDLE_HEIGHT = 92
local PADDLE_WIDTH = 14
local PADDLE_SPEED = 360
local BALL_RADIUS = 9
local STALE_AFTER = 1.5

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function lerp(current, target, amount)
  return current + (target - current) * amount
end

local function reset_ball(state, direction)
  state.ball_x = WIDTH / 2
  state.ball_y = (ARENA_TOP + ARENA_BOTTOM) / 2
  state.ball_vx = 260 * direction
  state.ball_vy = (state.score_p1 + state.score_p2) % 2 == 0 and 165 or -165
end

local function move_local_paddle(state, dt, controls)
  local movement = 0

  if controls.up then
    movement = movement - PADDLE_SPEED * dt
  end

  if controls.down then
    movement = movement + PADDLE_SPEED * dt
  end

  local maximum = ARENA_BOTTOM - PADDLE_HEIGHT

  if state.role == "p1" then
    state.p1_y = clamp(state.p1_y + movement, ARENA_TOP, maximum)
  else
    state.p2_y = clamp(state.p2_y + movement, ARENA_TOP, maximum)
  end
end

local function paddle_hit(ball_x, ball_y, paddle_x, paddle_y)
  return ball_x + BALL_RADIUS >= paddle_x
    and ball_x - BALL_RADIUS <= paddle_x + PADDLE_WIDTH
    and ball_y + BALL_RADIUS >= paddle_y
    and ball_y - BALL_RADIUS <= paddle_y + PADDLE_HEIGHT
end

local function update_authority_ball(state, dt)
  state.ball_x = state.ball_x + state.ball_vx * dt
  state.ball_y = state.ball_y + state.ball_vy * dt

  if state.ball_y - BALL_RADIUS <= ARENA_TOP then
    state.ball_y = ARENA_TOP + BALL_RADIUS
    state.ball_vy = math.abs(state.ball_vy)
  elseif state.ball_y + BALL_RADIUS >= ARENA_BOTTOM then
    state.ball_y = ARENA_BOTTOM - BALL_RADIUS
    state.ball_vy = -math.abs(state.ball_vy)
  end

  local left_x = 36
  local right_x = WIDTH - 36 - PADDLE_WIDTH

  if state.ball_vx < 0
      and paddle_hit(state.ball_x, state.ball_y, left_x, state.p1_y)
  then
    state.ball_x = left_x + PADDLE_WIDTH + BALL_RADIUS
    state.ball_vx = math.abs(state.ball_vx) * 1.025
    local offset = state.ball_y - (state.p1_y + PADDLE_HEIGHT / 2)
    state.ball_vy = state.ball_vy + offset * 3
  elseif state.ball_vx > 0
      and paddle_hit(state.ball_x, state.ball_y, right_x, state.p2_y)
  then
    state.ball_x = right_x - BALL_RADIUS
    state.ball_vx = -math.abs(state.ball_vx) * 1.025
    local offset = state.ball_y - (state.p2_y + PADDLE_HEIGHT / 2)
    state.ball_vy = state.ball_vy + offset * 3
  end

  if state.ball_x < -BALL_RADIUS then
    state.score_p2 = state.score_p2 + 1
    reset_ball(state, 1)
  elseif state.ball_x > WIDTH + BALL_RADIUS then
    state.score_p1 = state.score_p1 + 1
    reset_ball(state, -1)
  end
end

function M.new(role)
  if role ~= "p1" and role ~= "p2" then
    error("Pong role must be p1 or p2", 2)
  end

  return {
    role = role,
    p1_y = 240,
    p2_y = 240,
    target_p1_y = 240,
    target_p2_y = 240,
    ball_x = 400,
    ball_y = 300,
    ball_vx = 260,
    ball_vy = 160,
    target_ball_x = 400,
    target_ball_y = 300,
    target_ball_vx = 260,
    target_ball_vy = 160,
    score_p1 = 0,
    score_p2 = 0,
    send_seq = 0,
    last_snapshot_seq = 0,
    event_count = 0,
    resume_token = false,
    connected = false,
    last_update_at = nil,
  }
end

function M.apply_snapshot(state, snapshot, now)
  if snapshot.seq <= state.last_snapshot_seq then
    return false
  end

  state.last_snapshot_seq = snapshot.seq
  state.event_count = snapshot.event_count
  state.resume_token = snapshot.resume_token
  state.connected = true
  state.last_update_at = now
  state.target_p1_y = snapshot.p1_y
  state.target_p2_y = snapshot.p2_y
  state.score_p1 = snapshot.score_p1
  state.score_p2 = snapshot.score_p2

  if state.role == "p1" then
    state.target_ball_x = state.ball_x
    state.target_ball_y = state.ball_y
  else
    state.target_ball_x = snapshot.ball_x
    state.target_ball_y = snapshot.ball_y
    state.target_ball_vx = snapshot.ball_vx
    state.target_ball_vy = snapshot.ball_vy
  end

  return true
end

function M.update(state, dt, controls, now)
  move_local_paddle(state, dt, controls)
  local amount = math.min(1, dt * 10)

  if state.role == "p1" then
    state.p2_y = lerp(state.p2_y, state.target_p2_y, amount)
    update_authority_ball(state, dt)
  else
    state.p1_y = lerp(state.p1_y, state.target_p1_y, amount)
    state.ball_x = lerp(state.ball_x, state.target_ball_x, amount)
    state.ball_y = lerp(state.ball_y, state.target_ball_y, amount)
    state.ball_vx = state.target_ball_vx
    state.ball_vy = state.target_ball_vy
  end

  if state.last_update_at and now - state.last_update_at > STALE_AFTER then
    state.connected = false
  end
end

function M.next_input(state)
  state.send_seq = state.send_seq + 1

  return {
    seq = state.send_seq,
    paddle_y = state.role == "p1" and state.p1_y or state.p2_y,
    ball_x = state.ball_x,
    ball_y = state.ball_y,
    ball_vx = state.ball_vx,
    ball_vy = state.ball_vy,
    score_p1 = state.score_p1,
    score_p2 = state.score_p2,
  }
end

function M.diagnostics(state, now)
  local age

  if state.last_update_at then
    age = math.max(0, now - state.last_update_at)
  end

  return {
    role = state.role,
    connected = state.connected,
    event_count = state.event_count,
    update_age = age,
    resume_token = state.resume_token,
  }
end

M.WIDTH = WIDTH
M.HEIGHT = HEIGHT
M.ARENA_TOP = ARENA_TOP
M.ARENA_BOTTOM = ARENA_BOTTOM
M.PADDLE_HEIGHT = PADDLE_HEIGHT
M.PADDLE_WIDTH = PADDLE_WIDTH
M.BALL_RADIUS = BALL_RADIUS
M.STALE_AFTER = STALE_AFTER

return M
