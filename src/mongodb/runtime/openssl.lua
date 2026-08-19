local errors = require("mongodb.error")

local M = {}

local function crypto_error(operation)
  return errors.new({
    category = errors.CATEGORY.INTERNAL,
    message = "Cryptography " .. operation .. " operation failed",
  })
end

local function require_string(name, value, level)
  if type(value) ~= "string" then
    error(name .. " must be a string", level or 3)
  end
end

local function require_positive_integer(name, value, level)
  if math.type(value) ~= "integer" or value <= 0 then
    error(name .. " must be a positive integer", level or 3)
  end
end

local function protected_string_call(operation, callback)
  local ok, result = pcall(callback)

  if not ok or type(result) ~= "string" then
    return nil, crypto_error(operation)
  end

  return result
end

local function digest_call(operation, digest, data)
  require_string("digest input", data)

  return protected_string_call(operation, function()
    return digest(data)
  end)
end

local function hmac_call(operation, hmac, key, data)
  require_string("HMAC key", key)
  require_string("HMAC input", data)

  return protected_string_call("HMAC-" .. operation, function()
    return hmac(key, data)
  end)
end

local function xor_bytes(left, right)
  local output = {}

  for index = 1, #left do
    output[index] = string.char(left:byte(index) ~ right:byte(index))
  end

  return table.concat(output)
end

local function generic_hmac(digest, key, data)
  if #key > 64 then
    key = digest(key)
  end

  key = key .. string.rep("\0", 64 - #key)
  local inner_key = xor_bytes(key, string.rep(string.char(0x36), 64))
  local outer_key = xor_bytes(key, string.rep(string.char(0x5c), 64))
  return digest(outer_key .. digest(inner_key .. data))
end

local function pbkdf2_block(hmac, password, salt, iterations, block_index)
  local value, err = hmac(password, salt .. string.pack(">I4", block_index))

  if value == nil then
    return nil, err
  end

  local result = value

  for _ = 2, iterations do
    value, err = hmac(password, value)

    if value == nil then
      return nil, err
    end

    result = xor_bytes(result, value)
  end

  return result
end

local function pbkdf2_call(hmac, algorithm, digest_length, password, salt, iterations, length)
  require_string("PBKDF2 password", password)
  require_string("PBKDF2 salt", salt)
  require_positive_integer("PBKDF2 iteration count", iterations)
  require_positive_integer("PBKDF2 output length", length)

  local block_count = math.ceil(length / digest_length)

  if block_count > 0xffffffff then
    return nil, crypto_error("PBKDF2-" .. algorithm)
  end

  local output = {}

  for block_index = 1, block_count do
    local block, err = pbkdf2_block(hmac, password, salt, iterations, block_index)

    if block == nil then
      return nil, err
    end

    output[block_index] = block
  end

  return table.concat(output):sub(1, length)
end

local function entropy_call(random, count)
  local ok, bytes = pcall(random.bytes, count)

  if not ok or type(bytes) ~= "table" or #bytes ~= count then
    return nil, crypto_error("entropy")
  end

  local output = {}

  for index = 1, count do
    local byte = bytes[index]

    if math.type(byte) ~= "integer" or byte < 0 or byte > 255 then
      return nil, crypto_error("entropy")
    end

    output[index] = string.char(byte)
  end

  return table.concat(output)
end

function M.new()
  local md5 = require("md5")
  local random = require("lua-cryptorandom")
  local sha1 = require("sha1")
  local sha256 = require("mongodb.runtime.sha256")
  local adapter = { crypto = {}, entropy = {} }

  function adapter.crypto.md5(_, data)
    return digest_call("MD5", md5.sum, data)
  end

  function adapter.crypto.sha1(_, data)
    return digest_call("SHA-1", sha1.binary, data)
  end

  function adapter.crypto.sha256(_, data)
    return digest_call("SHA-256", sha256.digest, data)
  end

  function adapter.crypto.hmac_sha1(_, key, data)
    return hmac_call("SHA-1", sha1.hmac_binary, key, data)
  end

  function adapter.crypto.hmac_sha256(_, key, data)
    return hmac_call("SHA-256", function(secret, input)
      return generic_hmac(sha256.digest, secret, input)
    end, key, data)
  end

  function adapter.crypto.pbkdf2_sha1(_, password, salt, iterations, length)
    return pbkdf2_call(
      function(secret, input)
        return adapter.crypto:hmac_sha1(secret, input)
      end,
      "SHA-1",
      20,
      password,
      salt,
      iterations,
      length
    )
  end

  function adapter.crypto.pbkdf2_sha256(_, password, salt, iterations, length)
    return pbkdf2_call(
      function(secret, input)
        return adapter.crypto:hmac_sha256(secret, input)
      end,
      "SHA-256",
      32,
      password,
      salt,
      iterations,
      length
    )
  end

  function adapter.entropy.bytes(_, count)
    require_positive_integer("entropy byte count", count, 2)
    return entropy_call(random, count)
  end

  return adapter
end

return M
