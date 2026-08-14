local base64 = require("mongodb.bson.base64")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local ALGORITHM = "AWS4-HMAC-SHA256"
local BODY = "Action=GetCallerIdentity&Version=2011-06-15"
local GS2_CB_FLAG = "n"
local SERVICE = "sts"

local function auth_error(message, original)
  local options = {
    category = errors.CATEGORY.AUTHENTICATION,
    message = message,
  }

  if errors.is(original) then
    options.code = original.code
    options.code_name = original.code_name
    options.labels = {}
    options.retryable = original.retryable
      or errors.is(original, errors.CATEGORY.NETWORK)
    options.server = original.server
    options.timeout = original.timeout

    for index, label in ipairs(original.labels) do
      options.labels[index] = label
    end
  end

  return errors.new(options)
end

local function hex(value)
  return (value:gsub(".", function(character)
    return string.format("%02x", character:byte())
  end))
end

local function utc_timestamp(value)
  if type(value) ~= "number"
      or value ~= value
      or value < 0
      or value == math.huge
  then
    error("runtime wall clock must return a finite non-negative number", 3)
  end

  local seconds = math.floor(value)
  local days = seconds // 86400
  local seconds_in_day = seconds - days * 86400
  local hour = seconds_in_day // 3600
  local minute = seconds_in_day % 3600 // 60
  local second = seconds_in_day % 60
  local shifted_days = days + 719468
  local era = shifted_days // 146097
  local day_of_era = shifted_days - era * 146097
  local year_of_era = (
    day_of_era
      - day_of_era // 1460
      + day_of_era // 36524
      - day_of_era // 146096
  ) // 365
  local year = year_of_era + era * 400
  local day_of_year = day_of_era - (
    365 * year_of_era + year_of_era // 4 - year_of_era // 100
  )
  local month_part = (5 * day_of_year + 2) // 153
  local day = day_of_year - (153 * month_part + 2) // 5 + 1
  local month = month_part + (month_part < 10 and 3 or -9)

  if month <= 2 then
    year = year + 1
  end

  return string.format(
    "%04d%02d%02dT%02d%02d%02dZ",
    year,
    month,
    day,
    hour,
    minute,
    second
  )
end

local function region_from_host(host)
  if type(host) ~= "string"
      or #host == 0
      or #host > 255
      or host:sub(1, 1) == "."
      or host:sub(-1) == "."
      or host:find("..", 1, true)
  then
    return nil, auth_error("MONGODB-AWS server returned an invalid STS host")
  end

  if host == "aws.amazonaws.com" or host == "sts.amazonaws.com" then
    return "us-east-1"
  end

  local period = host:find(".", 1, true)

  if period == nil then
    return "us-east-1"
  end

  return host:match("^[^.]+%.([^.]+)")
end

local function crypto_result(value, err)
  if value == nil then
    return nil, auth_error("MONGODB-AWS signing failed", err)
  end

  if type(value) ~= "string" then
    error("runtime cryptography must return byte strings", 3)
  end

  return value
end

local function sign(runtime, credentials, server_nonce, host)
  local region, err = region_from_host(host)

  if not region then
    return nil, err
  end

  local timestamp = utc_timestamp(runtime.clock:wall_time())
  local date = timestamp:sub(1, 8)
  local scope = table.concat({ date, region, SERVICE, "aws4_request" }, "/")
  local headers = {
    { "content-length", tostring(#BODY) },
    { "content-type", "application/x-www-form-urlencoded" },
    { "host", host },
    { "x-amz-date", timestamp },
  }

  if credentials.session_token ~= nil then
    headers[#headers + 1] = {
      "x-amz-security-token",
      credentials.session_token,
    }
  end

  headers[#headers + 1] = { "x-mongodb-gs2-cb-flag", GS2_CB_FLAG }
  headers[#headers + 1] = {
    "x-mongodb-server-nonce",
    base64.encode(server_nonce),
  }

  local canonical_headers = {}
  local signed_headers = {}

  for index, header in ipairs(headers) do
    canonical_headers[index] = header[1] .. ":" .. header[2]
    signed_headers[index] = header[1]
  end

  canonical_headers = table.concat(canonical_headers, "\n")
  signed_headers = table.concat(signed_headers, ";")

  local body_hash
  body_hash, err = crypto_result(runtime.crypto:sha256(BODY))

  if not body_hash then
    return nil, err
  end

  local canonical_request = table.concat({
    "POST",
    "/",
    "",
    canonical_headers,
    "",
    signed_headers,
    hex(body_hash),
  }, "\n")
  local request_hash
  request_hash, err = crypto_result(runtime.crypto:sha256(canonical_request))

  if not request_hash then
    return nil, err
  end

  local string_to_sign = table.concat({
    ALGORITHM,
    timestamp,
    scope,
    hex(request_hash),
  }, "\n")
  local date_key
  date_key, err = crypto_result(runtime.crypto:hmac_sha256(
    "AWS4" .. credentials.password,
    date
  ))

  if not date_key then
    return nil, err
  end

  local region_key
  region_key, err = crypto_result(runtime.crypto:hmac_sha256(date_key, region))

  if not region_key then
    return nil, err
  end

  local service_key
  service_key, err = crypto_result(runtime.crypto:hmac_sha256(region_key, SERVICE))

  if not service_key then
    return nil, err
  end

  local signing_key
  signing_key, err = crypto_result(runtime.crypto:hmac_sha256(
    service_key,
    "aws4_request"
  ))

  if not signing_key then
    return nil, err
  end

  local signature
  signature, err = crypto_result(runtime.crypto:hmac_sha256(
    signing_key,
    string_to_sign
  ))

  if not signature then
    return nil, err
  end

  local authorization = ALGORITHM
    .. " Credential=" .. credentials.username .. "/" .. scope
    .. ", SignedHeaders=" .. signed_headers
    .. ", Signature=" .. hex(signature)

  return {
    authorization = authorization,
    timestamp = timestamp,
  }
end

local function validate_inputs(commands, runtime, credentials, options)
  if type(commands) ~= "table" or type(commands.command) ~= "function" then
    error("MONGODB-AWS authentication requires a command executor", 3)
  end

  if type(runtime) ~= "table"
      or type(runtime.clock) ~= "table"
      or type(runtime.clock.wall_time) ~= "function"
      or type(runtime.crypto) ~= "table"
      or type(runtime.crypto.sha256) ~= "function"
      or type(runtime.crypto.hmac_sha256) ~= "function"
      or type(runtime.entropy) ~= "table"
      or type(runtime.entropy.bytes) ~= "function"
  then
    error("MONGODB-AWS authentication requires runtime clock, crypto, and entropy", 3)
  end

  if type(credentials) ~= "table"
      or credentials.mechanism ~= "MONGODB-AWS"
      or credentials.source ~= "$external"
  then
    error("MONGODB-AWS credentials must select MONGODB-AWS on $external", 3)
  end

  if type(credentials.username) ~= "string" or credentials.username == "" then
    return nil, auth_error("MONGODB-AWS requires a resolved access key")
  end

  if type(credentials.password) ~= "string" or credentials.password == "" then
    return nil, auth_error("MONGODB-AWS requires a resolved secret key")
  end

  if credentials.session_token ~= nil
      and (type(credentials.session_token) ~= "string"
        or credentials.session_token == "")
  then
    return nil, auth_error("MONGODB-AWS session token must be a non-empty string")
  end

  if type(options) ~= "table" then
    error("MONGODB-AWS options must be a table", 3)
  end

  return true
end

local function response_payload(response, expected_done)
  if not bson.is_document(response) or response:get("done") ~= expected_done then
    return nil, auth_error("MONGODB-AWS server returned an invalid SASL response")
  end

  local payload = response:get("payload")

  if not bson.is_binary(payload)
      or payload.subtype ~= bson.BINARY_SUBTYPE.GENERIC
  then
    return nil, auth_error("MONGODB-AWS server returned an invalid SASL payload")
  end

  return payload.data
end

local function conversation_id(response)
  local value = response:get("conversationId")

  if bson.is_exact(value) then
    value = value:to_number()
  end

  if math.type(value) ~= "integer" then
    return nil, auth_error("MONGODB-AWS server returned an invalid conversation id")
  end

  return value
end

function M.authenticate(commands, runtime, credentials, options)
  options = options or {}
  local valid, err = validate_inputs(commands, runtime, credentials, options)

  if not valid then
    return nil, err
  end

  local client_nonce
  client_nonce, err = runtime.entropy:bytes(32)

  if not client_nonce then
    return nil, auth_error("MONGODB-AWS nonce generation failed", err)
  end

  if type(client_nonce) ~= "string" or #client_nonce ~= 32 then
    return nil, auth_error("MONGODB-AWS nonce generation returned invalid bytes")
  end

  local first_payload
  first_payload, err = bson.encode(bson.document({
    { "r", bson.binary(client_nonce) },
    { "p", bson.int32(110) },
  }))

  if not first_payload then
    return nil, auth_error("MONGODB-AWS client payload encoding failed", err)
  end

  local first_response
  first_response, err = commands:command("$external", bson.document({
    { "saslStart", 1 },
    { "mechanism", "MONGODB-AWS" },
    { "payload", bson.binary(first_payload) },
  }), {
    cancellation = options.cancellation,
    deadline = options.deadline,
  })

  if not first_response then
    return nil, auth_error("MONGODB-AWS saslStart failed", err)
  end

  local server_payload
  server_payload, err = response_payload(first_response, false)

  if not server_payload then
    return nil, err
  end

  local identifier
  identifier, err = conversation_id(first_response)

  if not identifier then
    return nil, err
  end

  local challenge
  challenge, err = bson.decode(server_payload)

  if not challenge then
    return nil, auth_error("MONGODB-AWS server payload decoding failed", err)
  end

  local server_nonce = challenge:get("s")
  local host = challenge:get("h")

  if not bson.is_binary(server_nonce)
      or server_nonce.subtype ~= bson.BINARY_SUBTYPE.GENERIC
      or #server_nonce.data ~= 64
      or server_nonce.data:sub(1, 32) ~= client_nonce
  then
    return nil, auth_error("MONGODB-AWS server returned an invalid nonce")
  end

  local signed
  signed, err = sign(runtime, credentials, server_nonce.data, host)

  if not signed then
    return nil, err
  end

  local second_entries = {
    { "a", signed.authorization },
    { "d", signed.timestamp },
  }

  if credentials.session_token ~= nil then
    second_entries[#second_entries + 1] = {
      "t",
      credentials.session_token,
    }
  end

  local second_payload
  second_payload, err = bson.encode(bson.document(second_entries))

  if not second_payload then
    return nil, auth_error("MONGODB-AWS client payload encoding failed", err)
  end

  local second_response
  second_response, err = commands:command("$external", bson.document({
    { "saslContinue", 1 },
    { "conversationId", identifier },
    { "payload", bson.binary(second_payload) },
  }), {
    cancellation = options.cancellation,
    deadline = options.deadline,
  })

  if not second_response then
    return nil, auth_error("MONGODB-AWS saslContinue failed", err)
  end

  local final_payload
  final_payload, err = response_payload(second_response, true)

  if not final_payload then
    return nil, err
  end

  local final_identifier
  final_identifier, err = conversation_id(second_response)

  if not final_identifier or final_identifier ~= identifier then
    return nil, err or auth_error(
      "MONGODB-AWS server changed the conversation id"
    )
  end

  return true
end

return M
