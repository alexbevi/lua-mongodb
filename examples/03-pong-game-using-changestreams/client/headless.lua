local game = require("game")
local protocol = require("protocol")

local state = game.new("p2")
local encoded = protocol.encode_input(game.next_input(state))
local input = assert(protocol.decode_input(encoded))
local snapshot = {
  seq = 2,
  p1_y = 200,
  p2_y = 300,
  ball_x = 440,
  ball_y = 320,
  ball_vx = 270,
  ball_vy = -150,
  score_p1 = 2,
  score_p2 = 1,
  event_count = 4,
  resume_token = true,
}
local fresh = game.apply_snapshot(state, snapshot, 10)
local stale = game.apply_snapshot(state, {
  seq = 1,
  p1_y = 999,
  p2_y = 999,
  ball_x = 999,
  ball_y = 999,
  ball_vx = 999,
  ball_vy = 999,
  score_p1 = 99,
  score_p2 = 99,
  event_count = 3,
  resume_token = false,
}, 10.01)

game.update(state, 0.05, { up = false, down = false }, 10.05)
local diagnostics = game.diagnostics(state, 10.1)

print("Protocol input: seq=" .. input.seq .. " role=" .. state.role)
print("Fresh snapshot accepted: " .. tostring(fresh))
print("Stale snapshot accepted: " .. tostring(stale))
print(string.format(
  "Interpolated remote: p1=%g ball_x=%g",
  state.p1_y,
  state.ball_x
))
print(string.format(
  "Diagnostics: connected=%s events=%d age=%.2f resume=%s",
  tostring(diagnostics.connected),
  diagnostics.event_count,
  diagnostics.update_age,
  diagnostics.resume_token and "available" or "missing"
))

game.update(state, 0.1, { up = false, down = false }, 12)
game.apply_snapshot(state, {
  seq = 3,
  p1_y = 205,
  p2_y = 300,
  ball_x = 450,
  ball_y = 325,
  ball_vx = 270,
  ball_vy = -150,
  score_p1 = 2,
  score_p2 = 1,
  event_count = 5,
  resume_token = true,
}, 12.1)
diagnostics = game.diagnostics(state, 12.1)
print("Rejoin snapshot: connected=" .. tostring(diagnostics.connected)
  .. " seq=" .. state.last_snapshot_seq)
