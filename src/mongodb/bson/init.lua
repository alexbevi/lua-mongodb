local codec = require("mongodb.bson.codec")
local value = require("mongodb.bson.value")

local M = {
  array = value.array,
  binary = value.binary,
  decode = codec.decode,
  document = value.document,
  encode = codec.encode,
  is_array = value.is_array,
  is_binary = value.is_binary,
  is_document = value.is_document,
  is_null = value.is_null,
  null = value.null,
}

return M
