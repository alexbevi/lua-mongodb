local MASK = 0xffffffff

local INITIAL_HASH = {
  0x6a09e667,
  0xbb67ae85,
  0x3c6ef372,
  0xa54ff53a,
  0x510e527f,
  0x9b05688c,
  0x1f83d9ab,
  0x5be0cd19,
}

local ROUND_CONSTANTS = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local M = {}

local function rotate_right(value, count)
  return ((value >> count) | (value << (32 - count))) & MASK
end

local function message_schedule(chunk)
  local words = {}
  local position = 1

  for index = 1, 16 do
    words[index], position = string.unpack(">I4", chunk, position)
  end

  for index = 17, 64 do
    local before = words[index - 15]
    local sigma0 = rotate_right(before, 7) ~ rotate_right(before, 18) ~ (before >> 3)
    before = words[index - 2]
    local sigma1 = rotate_right(before, 17) ~ rotate_right(before, 19) ~ (before >> 10)
    words[index] = (words[index - 16] + sigma0 + words[index - 7] + sigma1) & MASK
  end

  return words
end

local function compress(hash, chunk)
  local words = message_schedule(chunk)
  local a, b, c, d = hash[1], hash[2], hash[3], hash[4]
  local e, f, g, h = hash[5], hash[6], hash[7], hash[8]

  for index = 1, 64 do
    local sigma1 = rotate_right(e, 6) ~ rotate_right(e, 11) ~ rotate_right(e, 25)
    local choose = (e & f) ~ ((~e) & g)
    local temporary1 = (h + sigma1 + choose + ROUND_CONSTANTS[index] + words[index]) & MASK
    local sigma0 = rotate_right(a, 2) ~ rotate_right(a, 13) ~ rotate_right(a, 22)
    local majority = (a & b) ~ (a & c) ~ (b & c)
    local temporary2 = (sigma0 + majority) & MASK

    h, g, f, e = g, f, e, (d + temporary1) & MASK
    d, c, b, a = c, b, a, (temporary1 + temporary2) & MASK
  end

  hash[1] = (hash[1] + a) & MASK
  hash[2] = (hash[2] + b) & MASK
  hash[3] = (hash[3] + c) & MASK
  hash[4] = (hash[4] + d) & MASK
  hash[5] = (hash[5] + e) & MASK
  hash[6] = (hash[6] + f) & MASK
  hash[7] = (hash[7] + g) & MASK
  hash[8] = (hash[8] + h) & MASK
end

local function padded_message(input)
  local padding_length = (56 - ((#input + 1) % 64)) % 64
  return input .. "\128" .. string.rep("\0", padding_length) .. string.pack(">I8", #input * 8)
end

function M.digest(input)
  if type(input) ~= "string" then
    error("SHA-256 input must be a string", 2)
  end

  local hash = { table.unpack(INITIAL_HASH) }
  local message = padded_message(input)

  for position = 1, #message, 64 do
    compress(hash, message:sub(position, position + 63))
  end

  return string.pack(
    ">I4I4I4I4I4I4I4I4",
    hash[1], hash[2], hash[3], hash[4],
    hash[5], hash[6], hash[7], hash[8]
  )
end

return M
