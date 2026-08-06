local errors = require("mongodb.error")
local tables = require("mongodb.auth.stringprep_tables")

local M = {}

local MAX_CODE_POINT = 0x110000
local S_BASE = 0xac00
local L_BASE = 0x1100
local V_BASE = 0x1161
local T_BASE = 0x11a7
local L_COUNT = 19
local V_COUNT = 21
local T_COUNT = 28
local N_COUNT = V_COUNT * T_COUNT
local S_COUNT = L_COUNT * N_COUNT

local function auth_error(message)
  return errors.new({
    category = errors.CATEGORY.AUTHENTICATION,
    message = message,
  })
end

local function in_ranges(ranges, code_point)
  local low = 1
  local high = #ranges // 2

  while low <= high do
    local middle = (low + high) // 2
    local index = middle * 2 - 1
    local first = ranges[index]
    local last = ranges[index + 1]

    if code_point < first then
      high = middle - 1
    elseif code_point > last then
      low = middle + 1
    else
      return true
    end
  end

  return false
end

local function append_decomposition(output, code_point)
  if code_point >= S_BASE and code_point < S_BASE + S_COUNT then
    local syllable = code_point - S_BASE
    local leading = L_BASE + syllable // N_COUNT
    local vowel = V_BASE + syllable % N_COUNT // T_COUNT
    local trailing = syllable % T_COUNT

    output[#output + 1] = leading
    output[#output + 1] = vowel

    if trailing ~= 0 then
      output[#output + 1] = T_BASE + trailing
    end

    return
  end

  local decomposition = tables.decompositions[code_point]

  if decomposition then
    for _, item in ipairs(decomposition) do
      output[#output + 1] = item
    end
  else
    output[#output + 1] = code_point
  end
end

local function canonical_order(code_points)
  for index = 2, #code_points do
    local combining = tables.combining[code_points[index]] or 0
    local position = index

    while combining ~= 0 and position > 1 do
      local previous = tables.combining[code_points[position - 1]] or 0

      if previous == 0 or previous <= combining then
        break
      end

      code_points[position], code_points[position - 1]
        = code_points[position - 1], code_points[position]
      position = position - 1
    end
  end
end

local function hangul_composition(first, second)
  local leading = first - L_BASE

  if leading >= 0 and leading < L_COUNT then
    local vowel = second - V_BASE

    if vowel >= 0 and vowel < V_COUNT then
      return S_BASE + (leading * V_COUNT + vowel) * T_COUNT
    end
  end

  local syllable = first - S_BASE
  local trailing = second - T_BASE

  if syllable >= 0 and syllable < S_COUNT and syllable % T_COUNT == 0
      and trailing > 0 and trailing < T_COUNT
  then
    return first + trailing
  end
end

local function compose_pair(first, second)
  return hangul_composition(first, second)
    or tables.composition[first * MAX_CODE_POINT + second]
end

local function canonical_compose(code_points)
  if #code_points == 0 then
    return code_points
  end

  local output = { code_points[1] }
  local starter_index = 1
  local starter = code_points[1]
  local last_combining = 0

  for index = 2, #code_points do
    local code_point = code_points[index]
    local combining = tables.combining[code_point] or 0
    local composite = compose_pair(starter, code_point)

    if composite and (last_combining == 0 or last_combining < combining) then
      output[starter_index] = composite
      starter = composite
    else
      output[#output + 1] = code_point

      if combining == 0 then
        starter_index = #output
        starter = code_point
      end

      last_combining = combining
    end
  end

  return output
end

local function normalize_nfkc(code_points)
  local decomposed = {}

  for _, code_point in ipairs(code_points) do
    append_decomposition(decomposed, code_point)
  end

  canonical_order(decomposed)
  return canonical_compose(decomposed)
end

local function decode_and_map(input)
  local mapped = {}
  local ok = pcall(function()
    for _, code_point in utf8.codes(input) do
      if not in_ranges(tables.mapped_to_nothing, code_point) then
        if in_ranges(tables.non_ascii_space, code_point) then
          mapped[#mapped + 1] = 0x20
        else
          mapped[#mapped + 1] = code_point
        end
      end
    end
  end)

  if not ok then
    return nil, auth_error("SASLprep input is not valid UTF-8")
  end

  return mapped
end

function M.prepare(input)
  if type(input) ~= "string" then
    error("SASLprep input must be a string", 2)
  end

  local code_points, err = decode_and_map(input)

  if not code_points then
    return nil, err
  end

  code_points = normalize_nfkc(code_points)

  local has_randal = false
  local has_left_to_right = false

  for _, code_point in ipairs(code_points) do
    if in_ranges(tables.prohibited, code_point) then
      return nil, auth_error("SASLprep rejected prohibited Unicode input")
    end

    has_randal = has_randal or in_ranges(tables.randal, code_point)
    has_left_to_right = has_left_to_right or in_ranges(tables.left_to_right, code_point)
  end

  if has_randal then
    local first = code_points[1]
    local last = code_points[#code_points]

    if has_left_to_right or not in_ranges(tables.randal, first)
        or not in_ranges(tables.randal, last)
    then
      return nil, auth_error("SASLprep rejected bidirectional Unicode input")
    end
  end

  local output = {}

  for index, code_point in ipairs(code_points) do
    output[index] = utf8.char(code_point)
  end

  return table.concat(output)
end

return M
