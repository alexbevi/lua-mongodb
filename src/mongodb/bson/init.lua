local codec = require("mongodb.bson.codec")
local tagged = require("mongodb.bson.tagged")
local value = require("mongodb.bson.value")

local M = {
  BINARY_SUBTYPE = value.BINARY_SUBTYPE,
  array = value.array,
  binary = value.binary,
  decode = codec.decode,
  datetime = tagged.datetime,
  document = value.document,
  encode = codec.encode,
  is_array = value.is_array,
  is_binary = value.is_binary,
  is_document = value.is_document,
  is_null = value.is_null,
  is_tagged = tagged.is,
  code = tagged.code,
  max_key = tagged.max_key,
  min_key = tagged.min_key,
  null = value.null,
  object_id = tagged.object_id,
  object_id_generator = tagged.object_id_generator,
  regex = tagged.regex,
  timestamp = tagged.timestamp,
}

return M
