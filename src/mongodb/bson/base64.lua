local M = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DECODE = {}

for index = 1, #ALPHABET do
  DECODE[ALPHABET:sub(index, index)] = index - 1
end

function M.encode(data)
  local result = {}

  for position = 1, #data, 3 do
    local first = data:byte(position)
    local second = data:byte(position + 1)
    local third = data:byte(position + 2)
    local value = (first << 16) | ((second or 0) << 8) | (third or 0)

    result[#result + 1] = ALPHABET:sub(((value >> 18) & 0x3f) + 1, ((value >> 18) & 0x3f) + 1)
    result[#result + 1] = ALPHABET:sub(((value >> 12) & 0x3f) + 1, ((value >> 12) & 0x3f) + 1)
    result[#result + 1] = second
      and ALPHABET:sub(((value >> 6) & 0x3f) + 1, ((value >> 6) & 0x3f) + 1)
      or "="
    result[#result + 1] = third
      and ALPHABET:sub((value & 0x3f) + 1, (value & 0x3f) + 1)
      or "="
  end

  return table.concat(result)
end

function M.decode(encoded)
  if type(encoded) ~= "string" or #encoded % 4 ~= 0 then
    return nil, "base64 input length must be divisible by four"
  end

  local result = {}

  for position = 1, #encoded, 4 do
    local characters = encoded:sub(position, position + 3)
    local first = DECODE[characters:sub(1, 1)]
    local second = DECODE[characters:sub(2, 2)]
    local third_character = characters:sub(3, 3)
    local fourth_character = characters:sub(4, 4)
    local third = DECODE[third_character]
    local fourth = DECODE[fourth_character]
    local final_group = position + 3 == #encoded

    if first == nil or second == nil
        or third == nil and third_character ~= "="
        or fourth == nil and fourth_character ~= "="
        or not final_group and (third_character == "=" or fourth_character == "=")
        or third_character == "=" and fourth_character ~= "=" then
      return nil, "invalid base64 encoding"
    end

    local value = (first << 18) | (second << 12) | ((third or 0) << 6) | (fourth or 0)
    result[#result + 1] = string.char((value >> 16) & 0xff)

    if third_character ~= "=" then
      result[#result + 1] = string.char((value >> 8) & 0xff)
    end

    if fourth_character ~= "=" then
      result[#result + 1] = string.char(value & 0xff)
    end
  end

  return table.concat(result)
end

return M
