local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local op_compressed = require("mongodb.wire.op_compressed")
local op_msg = require("mongodb.wire.op_msg")

describe("OP_COMPRESSED framing", function()
  it("encodes one compressed OP_MSG body byte for byte", function()
    local original = assert(op_msg.encode({
      body = bson.document({ { "ping", 1 }, { "$db", "admin" } }),
      request_id = 41,
    }))
    local original_body = original:sub(17)
    local compressed_body = "\222\173\190\239"
    local observed_body
    local observed_level
    local compressor = {
      compressor_id = 2,
      compress = function(_, body, level)
        observed_body = body
        observed_level = level
        return compressed_body
      end,
      decompress = function()
        error("must not decompress")
      end,
      name = "zlib",
    }
    local bytes = assert(op_compressed.encode({
      body = original_body,
      compression_level = 6,
      compressor = compressor,
      original_opcode = op_msg.OP_CODE,
      request_id = 42,
    }))
    local expected = string.pack(
      "<i4i4i4i4i4i4B",
      25 + #compressed_body,
      42,
      0,
      2012,
      2013,
      #original_body,
      2
    ) .. compressed_body

    assert.are.equal(original_body, observed_body)
    assert.are.equal(6, observed_level)
    assert.are.equal(expected, bytes)
  end)

  it("returns a structured protocol error when compression fails", function()
    local cause = errors.new({
      category = errors.CATEGORY.INTERNAL,
      message = "provider failed",
    })
    local bytes, err = op_compressed.encode({
      body = "payload",
      compressor = {
        compressor_id = 2,
        compress = function()
          return nil, cause
        end,
        decompress = function()
          error("must not decompress")
        end,
        name = "zlib",
      },
      original_opcode = op_msg.OP_CODE,
      request_id = 42,
    })

    assert.is_nil(bytes)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
    assert.are.equal("OP_COMPRESSED compression failed", err.message)
    assert.are.equal(cause, err.cause)
  end)
end)
