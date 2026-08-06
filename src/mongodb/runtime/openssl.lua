local errors = require("mongodb.error")

local M = {}

local function crypto_error(operation)
  return errors.new({
    category = errors.CATEGORY.INTERNAL,
    message = "OpenSSL " .. operation .. " operation failed",
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

local function digest_call(digest, algorithm, data)
  require_string("digest input", data)

  local ok, result = pcall(function()
    return digest.new(algorithm):final(data)
  end)

  if not ok then
    return nil, crypto_error(algorithm)
  end

  return result
end

local function hmac_call(hmac, algorithm, key, data)
  require_string("HMAC key", key)
  require_string("HMAC input", data)

  local ok, result = pcall(function()
    return hmac.new(key, algorithm):final(data)
  end)

  if not ok then
    return nil, crypto_error("HMAC-" .. algorithm)
  end

  return result
end

local function pbkdf2_call(kdf, algorithm, password, salt, iterations, length)
  require_string("PBKDF2 password", password)
  require_string("PBKDF2 salt", salt)
  require_positive_integer("PBKDF2 iteration count", iterations)
  require_positive_integer("PBKDF2 output length", length)

  local ok, result = pcall(function()
    return kdf.derive({
      iter = iterations,
      md = algorithm,
      outlen = length,
      pass = password,
      salt = salt,
      type = "PBKDF2",
    })
  end)

  if not ok then
    return nil, crypto_error("PBKDF2-" .. algorithm)
  end

  return result
end

function M.new()
  local digest = require("openssl.digest")
  local hmac = require("openssl.hmac")
  local kdf = require("openssl.kdf")
  local rand = require("openssl.rand")
  local adapter = { crypto = {}, entropy = {} }

  function adapter.crypto.md5(_, data)
    return digest_call(digest, "md5", data)
  end

  function adapter.crypto.sha1(_, data)
    return digest_call(digest, "sha1", data)
  end

  function adapter.crypto.sha256(_, data)
    return digest_call(digest, "sha256", data)
  end

  function adapter.crypto.hmac_sha1(_, key, data)
    return hmac_call(hmac, "sha1", key, data)
  end

  function adapter.crypto.hmac_sha256(_, key, data)
    return hmac_call(hmac, "sha256", key, data)
  end

  function adapter.crypto.pbkdf2_sha1(_, password, salt, iterations, length)
    return pbkdf2_call(kdf, "sha1", password, salt, iterations, length)
  end

  function adapter.crypto.pbkdf2_sha256(_, password, salt, iterations, length)
    return pbkdf2_call(kdf, "sha256", password, salt, iterations, length)
  end

  function adapter.entropy.bytes(_, count)
    require_positive_integer("entropy byte count", count, 2)

    local ok, result = pcall(rand.bytes, count)

    if not ok or type(result) ~= "string" or #result ~= count then
      return nil, crypto_error("entropy")
    end

    return result
  end

  return adapter
end

return M
