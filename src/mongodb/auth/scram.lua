local base64 = require("mongodb.bson.base64")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime")
local saslprep = require("mongodb.auth.saslprep")

local M = {}

local CACHES = setmetatable({}, { __mode = "k" })
local MECHANISMS = {
  ["SCRAM-SHA-1"] = {
    digest = "sha1",
    digest_length = 20,
    hmac = "hmac_sha1",
    pbkdf2 = "pbkdf2_sha1",
  },
  ["SCRAM-SHA-256"] = {
    digest = "sha256",
    digest_length = 32,
    hmac = "hmac_sha256",
    pbkdf2 = "pbkdf2_sha256",
  },
}

local function auth_error(message, original)
  local options = {
    category = errors.CATEGORY.AUTHENTICATION,
    message = message,
  }

  if errors.is(original) then
    options.code = original.code
    options.code_name = original.code_name
    options.retryable = original.retryable
    options.server = original.server
    options.timeout = original.timeout
    options.labels = {}

    for index, label in ipairs(original.labels) do
      options.labels[index] = label
    end
  end

  return errors.new(options)
end

local function number_value(value)
  if type(value) == "number" then
    return value
  end

  if bson.is_exact(value) then
    return value:to_number()
  end
end

local function parse_payload(payload)
  local fields = {}
  local position = 1

  if payload == "" then
    return fields
  end

  while position <= #payload do
    local separator = payload:find(",", position, true)
    local item = separator and payload:sub(position, separator - 1) or payload:sub(position)
    local key, value = item:match("^([A-Za-z])=(.*)$")

    if not key or fields[key] ~= nil then
      return nil, auth_error("SCRAM server returned a malformed payload")
    end

    fields[key] = value

    if not separator then
      break
    end

    position = separator + 1

    if position > #payload then
      return nil, auth_error("SCRAM server returned a malformed payload")
    end
  end

  if fields.e ~= nil then
    return nil, auth_error("SCRAM server rejected authentication")
  end

  if fields.m ~= nil then
    return nil, auth_error("SCRAM server requires an unsupported extension")
  end

  return fields
end

local function payload_from(response)
  if not bson.is_document(response) then
    return nil, auth_error("SCRAM server returned an invalid response")
  end

  local payload = response:get("payload")

  if not bson.is_binary(payload) or payload.subtype ~= bson.BINARY_SUBTYPE.GENERIC then
    return nil, auth_error("SCRAM server returned an invalid payload")
  end

  return payload.data
end

local function command(commands, source, body, options)
  local response, err = commands:command(source, body, {
    cancellation = options.cancellation,
    deadline = options.deadline,
  })

  if not response then
    return nil, auth_error("SCRAM authentication command failed", err)
  end

  return response
end

local function hex(bytes)
  return (bytes:gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end))
end

local function xor_bytes(left, right)
  local output = {}

  if #left ~= #right then
    error("SCRAM XOR inputs must have equal lengths", 2)
  end

  for index = 1, #left do
    output[index] = string.char(left:byte(index) ~ right:byte(index))
  end

  return table.concat(output)
end

local function constant_time_equal(left, right)
  local difference = #left ~ #right
  local length = math.max(#left, #right)

  for index = 1, length do
    difference = difference | ((left:byte(index) or 0) ~ (right:byte(index) or 0))
  end

  return difference == 0
end

local function crypto_call(runtime, operation, ...)
  local result = runtime.crypto[operation](runtime.crypto, ...)

  if not result then
    return nil, auth_error("SCRAM cryptographic operation failed")
  end

  return result
end

local function password_data(runtime, credentials, mechanism)
  if mechanism == "SCRAM-SHA-256" then
    return saslprep.prepare(credentials.password)
  end

  local digest, err = crypto_call(
    runtime,
    "md5",
    credentials.username .. ":mongo:" .. credentials.password
  )

  if not digest then
    return nil, err
  end

  return hex(digest)
end

local function keys_for(runtime, credentials, mechanism, properties, salt_text, iterations)
  local cache = CACHES[credentials]

  if cache and cache.mechanism == mechanism and cache.salt == salt_text
      and cache.iterations == iterations
  then
    return cache.client_key, cache.server_key
  end

  local password, err = password_data(runtime, credentials, mechanism)

  if not password then
    return nil, nil, err
  end

  local salt = base64.decode(salt_text)

  if not salt then
    return nil, nil, auth_error("SCRAM server returned an invalid salt")
  end

  local salted
  salted, err = crypto_call(
    runtime,
    properties.pbkdf2,
    password,
    salt,
    iterations,
    properties.digest_length
  )

  if not salted then
    return nil, nil, err
  end

  local client_key
  client_key, err = crypto_call(runtime, properties.hmac, salted, "Client Key")

  if not client_key then
    return nil, nil, err
  end

  local server_key
  server_key, err = crypto_call(runtime, properties.hmac, salted, "Server Key")

  if not server_key then
    return nil, nil, err
  end

  CACHES[credentials] = {
    client_key = client_key,
    iterations = iterations,
    mechanism = mechanism,
    salt = salt_text,
    server_key = server_key,
  }
  return client_key, server_key
end

local function validate_inputs(commands, runtime, credentials, options)
  if type(commands) ~= "table" or type(commands.command) ~= "function" then
    error("SCRAM authentication requires a command executor", 3)
  end

  runtime_contract.validate(runtime)

  if type(credentials) ~= "table" then
    error("SCRAM credentials must be a table", 3)
  end

  if type(credentials.username) ~= "string" or credentials.username == "" then
    error("SCRAM username must be a non-empty string", 3)
  end

  if type(credentials.password) ~= "string" then
    error("SCRAM password must be a string", 3)
  end

  if type(credentials.source) ~= "string" or credentials.source == "" then
    error("SCRAM source must be a non-empty string", 3)
  end

  if not MECHANISMS[credentials.mechanism] then
    error("SCRAM mechanism must be SCRAM-SHA-1 or SCRAM-SHA-256", 3)
  end

  if type(options) ~= "table" then
    error("SCRAM options must be a table", 3)
  end
end

function M.authenticate(commands, runtime, credentials, options)
  options = options or {}
  validate_inputs(commands, runtime, credentials, options)

  local mechanism = credentials.mechanism
  local properties = MECHANISMS[mechanism]
  local entropy = runtime.entropy:bytes(32)

  if not entropy then
    return nil, auth_error("SCRAM secure entropy generation failed")
  end

  if type(entropy) ~= "string" or #entropy ~= 32 then
    error("runtime entropy must return exactly the requested byte count", 2)
  end

  local nonce = base64.encode(entropy)
  local escaped_username = credentials.username:gsub("=", "=3D"):gsub(",", "=2C")
  local first_bare = "n=" .. escaped_username .. ",r=" .. nonce
  local response, err

  response, err = command(commands, credentials.source, bson.document({
    { "saslStart", 1 },
    { "mechanism", mechanism },
    { "payload", bson.binary("n,," .. first_bare) },
    { "options", bson.document({ { "skipEmptyExchange", true } }) },
  }), options)

  if not response then
    return nil, err
  end

  local conversation_id = response:get("conversationId")

  if math.type(number_value(conversation_id)) ~= "integer" then
    return nil, auth_error("SCRAM server returned an invalid conversation identifier")
  end

  local server_first
  server_first, err = payload_from(response)

  if not server_first then
    return nil, err
  end

  local fields
  fields, err = parse_payload(server_first)

  if not fields then
    return nil, err
  end

  local iterations = fields.i and tonumber(fields.i)

  if type(fields.i) ~= "string" or not fields.i:match("^[0-9]+$")
      or math.type(iterations) ~= "integer"
      or iterations < 4096
  then
    return nil, auth_error("SCRAM server returned an invalid iteration count")
  end

  if type(fields.r) ~= "string" or fields.r:sub(1, #nonce) ~= nonce then
    return nil, auth_error("SCRAM server returned an invalid nonce")
  end

  if type(fields.s) ~= "string" or fields.s == "" then
    return nil, auth_error("SCRAM server returned an invalid salt")
  end

  local client_key, server_key
  client_key, server_key, err = keys_for(
    runtime,
    credentials,
    mechanism,
    properties,
    fields.s,
    iterations
  )

  if not client_key then
    return nil, err
  end

  local stored_key
  stored_key, err = crypto_call(runtime, properties.digest, client_key)

  if not stored_key then
    return nil, err
  end

  local without_proof = "c=biws,r=" .. fields.r
  local auth_message = first_bare .. "," .. server_first .. "," .. without_proof
  local client_signature
  client_signature, err = crypto_call(runtime, properties.hmac, stored_key, auth_message)

  if not client_signature then
    return nil, err
  end

  local server_signature
  server_signature, err = crypto_call(runtime, properties.hmac, server_key, auth_message)

  if not server_signature then
    return nil, err
  end

  response, err = command(commands, credentials.source, bson.document({
    { "saslContinue", 1 },
    { "conversationId", conversation_id },
    { "payload", bson.binary(
      without_proof .. ",p=" .. base64.encode(xor_bytes(client_key, client_signature))
    ) },
  }), options)

  if not response then
    return nil, err
  end

  local server_final
  server_final, err = payload_from(response)

  if not server_final then
    return nil, err
  end

  fields, err = parse_payload(server_final)

  if not fields then
    return nil, err
  end

  if type(fields.v) ~= "string"
      or not constant_time_equal(fields.v, base64.encode(server_signature))
  then
    return nil, auth_error("SCRAM server returned an invalid signature")
  end

  if response:get("done") == true then
    return true
  end

  response, err = command(commands, credentials.source, bson.document({
    { "saslContinue", 1 },
    { "conversationId", conversation_id },
    { "payload", bson.binary("") },
  }), options)

  if not response then
    return nil, err
  end

  if response:get("done") ~= true then
    return nil, auth_error("SCRAM conversation did not complete")
  end

  return true
end

return M
