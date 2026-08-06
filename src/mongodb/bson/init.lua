local codec = require("mongodb.bson.codec")
local exact = require("mongodb.bson.exact")
local tagged = require("mongodb.bson.tagged")
local value = require("mongodb.bson.value")

local M = {
  BINARY_SUBTYPE = value.BINARY_SUBTYPE,
  array = value.array,
  binary = value.binary,
  decode = codec.decode,
  decimal128 = exact.decimal128,
  decimal128_from_bid = exact.decimal128_from_bid,
  datetime = tagged.datetime,
  document = value.document,
  double = exact.double,
  encode = codec.encode,
  is_array = value.is_array,
  is_binary = value.is_binary,
  is_document = value.is_document,
  is_exact = exact.is,
  is_null = value.is_null,
  is_tagged = tagged.is,
  code = tagged.code,
  db_pointer = tagged.db_pointer,
  max_key = tagged.max_key,
  min_key = tagged.min_key,
  null = value.null,
  object_id = tagged.object_id,
  object_id_generator = tagged.object_id_generator,
  regex = tagged.regex,
  symbol = tagged.symbol,
  int32 = exact.int32,
  int64 = exact.int64,
  json = require("mongodb.bson.json"),
  timestamp = tagged.timestamp,
  undefined = tagged.undefined,
}

return M
