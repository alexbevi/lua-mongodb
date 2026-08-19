local M = {}

local VERSION = "PONG1"

local function split(payload)
  local fields = {}

  for field in string.gmatch(payload .. "|", "(.-)|") do
    fields[#fields + 1] = field
  end

  return fields
end

local function numeric(fields, index, name)
  local value = tonumber(fields[index])

  if value == nil then
    return nil, name .. " must be numeric"
  end

  return value
end

function M.encode_input(state)
  return table.concat({
    VERSION,
    "INPUT",
    state.seq,
    state.paddle_y,
    state.ball_x,
    state.ball_y,
    state.ball_vx,
    state.ball_vy,
    state.score_p1,
    state.score_p2,
  }, "|")
end

function M.decode_input(payload)
  local fields = split(payload)

  if fields[1] ~= VERSION or fields[2] ~= "INPUT" or #fields ~= 10 then
    return nil, "invalid Pong input message"
  end

  local names = {
    "seq",
    "paddle_y",
    "ball_x",
    "ball_y",
    "ball_vx",
    "ball_vy",
    "score_p1",
    "score_p2",
  }
  local state = {}

  for index, name in ipairs(names) do
    local value, err = numeric(fields, index + 2, name)

    if value == nil then
      return nil, err
    end

    state[name] = value
  end

  return state
end


function M.encode_snapshot(state)
  return table.concat({
    VERSION,
    "SNAPSHOT",
    state.seq,
    state.p1_y,
    state.p2_y,
    state.ball_x,
    state.ball_y,
    state.ball_vx,
    state.ball_vy,
    state.score_p1,
    state.score_p2,
    state.event_count,
    state.resume_token and "yes" or "no",
  }, "|")
end

function M.decode_snapshot(payload)
  local fields = split(payload)

  if fields[1] ~= VERSION or fields[2] ~= "SNAPSHOT" or #fields ~= 13 then
    return nil, "invalid Pong snapshot message"
  end

  local names = {
    "seq",
    "p1_y",
    "p2_y",
    "ball_x",
    "ball_y",
    "ball_vx",
    "ball_vy",
    "score_p1",
    "score_p2",
    "event_count",
  }
  local state = {}

  for index, name in ipairs(names) do
    local value, err = numeric(fields, index + 2, name)

    if value == nil then
      return nil, err
    end

    state[name] = value
  end

  state.resume_token = fields[13] == "yes"
  return state
end

return M
