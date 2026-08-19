-- luacheck: globals love

local socket = require("socket")
local protocol = require("protocol")
local game = require("game")

local SEND_INTERVAL = 1 / 20
local COLORS = {
  background = { 0.025, 0.055, 0.07 },
  panel = { 0.045, 0.095, 0.11 },
  panel_border = { 0.11, 0.23, 0.25 },
  green = { 0.2, 0.82, 0.45 },
  green_dim = { 0.08, 0.36, 0.23 },
  white = { 0.9, 0.96, 0.94 },
  muted = { 0.48, 0.62, 0.62 },
  warning = { 1, 0.58, 0.25 },
}

local state
local udp
local send_accumulator = 0
local protocol_error
local fonts = {}
local default_errorhandler = love.errorhandler

function love.errorhandler(message)
  io.stderr:write("LÖVE error: " .. tostring(message) .. "\n")
  return default_errorhandler(message)
end

local function role_from_arguments(arguments)
  for _, value in ipairs(arguments or {}) do
    if value == "p1" or value == "p2" then
      return value
    end
  end

  return nil
end

local function receive_snapshots(now)
  while true do
    local payload, err = udp:receive()

    if not payload then
      if err ~= "timeout" and err ~= "connection refused" then
        protocol_error = err
      end

      return
    end

    local snapshot, decode_err = protocol.decode_snapshot(payload)

    if snapshot then
      game.apply_snapshot(state, snapshot, now)
      protocol_error = nil
    else
      protocol_error = decode_err
    end
  end
end

local function publish_input()
  local payload = protocol.encode_input(game.next_input(state))
  local sent, err = udp:send(payload)

  if not sent and err ~= "timeout" and err ~= "connection refused" then
    protocol_error = err
  end
end

local function controls_for_role()
  if state.role == "p1" then
    return {
      up = love.keyboard.isDown("w"),
      down = love.keyboard.isDown("s"),
    }
  end

  return {
    up = love.keyboard.isDown("up"),
    down = love.keyboard.isDown("down"),
  }
end

local function set_color(color, alpha)
  love.graphics.setColor(color[1], color[2], color[3], alpha or 1)
end

local function draw_panel(x, y, width, height)
  set_color(COLORS.panel, 0.96)
  love.graphics.rectangle("fill", x, y, width, height, 9, 9)
  set_color(COLORS.panel_border)
  love.graphics.rectangle("line", x, y, width, height, 9, 9)
end

local function draw_header()
  set_color(COLORS.white)
  love.graphics.setFont(fonts.title)
  love.graphics.print("MONGO", 24, 18)
  set_color(COLORS.green)
  love.graphics.print("PONG", 133, 18)
  set_color(COLORS.muted)
  love.graphics.setFont(fonts.small)
  love.graphics.print("CHANGE STREAM ARENA", 26, 55)

  local role_text = state.role == "p1" and "PLAYER 1 · AUTHORITY" or "PLAYER 2"
  draw_panel(584, 18, 192, 48)
  set_color(COLORS.green)
  love.graphics.setFont(fonts.small_bold)
  love.graphics.printf(role_text, 596, 35, 168, "center")
end

local function draw_arena()
  set_color(COLORS.panel, 0.7)
  love.graphics.rectangle(
    "fill",
    18,
    game.ARENA_TOP - 10,
    game.WIDTH - 36,
    game.ARENA_BOTTOM - game.ARENA_TOP + 20,
    12,
    12
  )
  set_color(COLORS.panel_border)
  love.graphics.rectangle(
    "line",
    18,
    game.ARENA_TOP - 10,
    game.WIDTH - 36,
    game.ARENA_BOTTOM - game.ARENA_TOP + 20,
    12,
    12
  )

  for y = game.ARENA_TOP, game.ARENA_BOTTOM - 14, 28 do
    set_color(COLORS.panel_border, 0.75)
    love.graphics.rectangle("fill", game.WIDTH / 2 - 2, y, 4, 14, 2, 2)
  end

  love.graphics.setFont(fonts.score)
  set_color(COLORS.white, 0.92)
  love.graphics.printf(tostring(state.score_p1), 290, 124, 80, "center")
  love.graphics.printf(tostring(state.score_p2), 430, 124, 80, "center")

  local local_p1 = state.role == "p1"
  set_color(local_p1 and COLORS.green or COLORS.white)
  love.graphics.rectangle(
    "fill",
    36,
    state.p1_y,
    game.PADDLE_WIDTH,
    game.PADDLE_HEIGHT,
    7,
    7
  )
  set_color(local_p1 and COLORS.white or COLORS.green)
  love.graphics.rectangle(
    "fill",
    game.WIDTH - 36 - game.PADDLE_WIDTH,
    state.p2_y,
    game.PADDLE_WIDTH,
    game.PADDLE_HEIGHT,
    7,
    7
  )

  set_color(COLORS.green_dim, 0.5)
  love.graphics.circle("fill", state.ball_x, state.ball_y, game.BALL_RADIUS + 7)
  set_color(COLORS.green)
  love.graphics.circle("fill", state.ball_x, state.ball_y, game.BALL_RADIUS)
  set_color(COLORS.white, 0.75)
  love.graphics.circle(
    "fill",
    state.ball_x - 2,
    state.ball_y - 2,
    game.BALL_RADIUS / 3
  )
end

local function diagnostic_row(label, value, x, y, value_color)
  set_color(COLORS.muted)
  love.graphics.setFont(fonts.tiny)
  love.graphics.print(label, x, y)
  set_color(value_color or COLORS.white)
  love.graphics.setFont(fonts.small_bold)
  love.graphics.print(value, x, y + 12)
end

local function draw_diagnostics()
  local now = love.timer.getTime()
  local diagnostics = game.diagnostics(state, now)
  draw_panel(18, 554, 764, 38)
  local connected = diagnostics.connected
  local age = diagnostics.update_age and string.format("%.2fs", diagnostics.update_age)
    or "waiting"

  diagnostic_row("Role", diagnostics.role:upper(), 32, 560, COLORS.green)
  diagnostic_row(
    "Bridge",
    connected and "LIVE" or "WAITING",
    120,
    560,
    connected and COLORS.green or COLORS.warning
  )
  diagnostic_row("Change events", tostring(diagnostics.event_count), 234, 560)
  diagnostic_row("Last update", age, 378, 560)
  diagnostic_row(
    "Resume token",
    diagnostics.resume_token and "AVAILABLE" or "WAITING",
    502,
    560,
    diagnostics.resume_token and COLORS.green or COLORS.muted
  )
  diagnostic_row("Render", love.timer.getFPS() .. " FPS", 662, 560)

  set_color(protocol_error and COLORS.warning or COLORS.muted)
  love.graphics.setFont(fonts.tiny)
  local message

  if protocol_error then
    message = protocol_error
  elseif not connected then
    message = "Start this player's Lua 5.4 bridge to join"
  else
    local controls = state.role == "p1" and "W / S" or "UP / DOWN"
    message = controls .. " TO MOVE · ESC TO QUIT"
  end

  love.graphics.printf(message, 250, 78, 300, "center")
end

function love.load(arguments)
  local role = role_from_arguments(arguments)

  if not role then
    error("Launch with: love client -- p1  (or p2)")
  end

  state = game.new(role)
  local port = role == "p1" and 27101 or 27102
  udp = assert(socket.udp())
  assert(udp:setpeername("127.0.0.1", port))
  assert(udp:settimeout(0))
  fonts.title = love.graphics.newFont(30)
  fonts.score = love.graphics.newFont(42)
  fonts.small = love.graphics.newFont(11)
  fonts.small_bold = love.graphics.newFont(12)
  fonts.tiny = love.graphics.newFont(9)
  love.window.setTitle("MongoDB Pong · " .. role:upper())
  love.graphics.setLineWidth(1.5)
end

function love.update(dt)
  local now = love.timer.getTime()
  receive_snapshots(now)
  game.update(state, math.min(dt, 0.05), controls_for_role(), now)
  send_accumulator = send_accumulator + dt

  while send_accumulator >= SEND_INTERVAL do
    publish_input()
    send_accumulator = send_accumulator - SEND_INTERVAL
  end
end

function love.draw()
  love.graphics.clear(
    COLORS.background[1],
    COLORS.background[2],
    COLORS.background[3],
    1
  )
  draw_header()
  draw_arena()
  draw_diagnostics()
end

function love.keypressed(key)
  if key == "escape" then
    love.event.quit()
  end
end

function love.quit()
  if udp then
    udp:close()
  end
end
