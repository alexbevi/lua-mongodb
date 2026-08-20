local bson = require("mongodb.bson")
local executor = require("mongodb.command.executor")
local errors = require("mongodb.error")
local op_compressed = require("mongodb.wire.op_compressed")
local op_msg = require("mongodb.wire.op_msg")

local function compressed_frame(original, compressor_id, compressed, declared_size)
  local _, request_id, response_to, original_opcode = string.unpack(
    "<i4i4i4i4",
    original
  )
  local uncompressed_size = declared_size or #original - 16

  return string.pack(
    "<i4i4i4i4i4i4B",
    25 + #compressed,
    request_id,
    response_to,
    2012,
    original_opcode,
    uncompressed_size,
    compressor_id
  ) .. compressed
end

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

  it("decodes a reply by envelope compressor id without negotiated state", function()
    local original = assert(op_msg.encode({
      body = bson.document({ { "ok", 1 }, { "value", "pong" } }),
      direction = "response",
      request_id = 91,
      response_to = 42,
    }))
    local compressed = "compressed reply"
    local observed
    local provider = {
      compressor_id = 2,
      compress = function()
        error("must not compress")
      end,
      decompress = function(_, input)
        observed = input
        return original:sub(17)
      end,
      name = "zlib",
    }
    local recovered = assert(op_compressed.decode(
      compressed_frame(original, 2, compressed),
      { compression = { zlib = provider }, max_message_size = 4096 }
    ))
    local reply = assert(op_msg.decode(recovered, {
      direction = "response",
      expected_response_to = 42,
      max_message_size = 4096,
    }))

    assert.are.equal(compressed, observed)
    assert.are.equal(original, recovered)
    assert.are.equal("pong", reply.body:get("value"))
  end)

  it("rejects unknown, malformed, oversized, and failed compressed replies", function()
    local original = assert(op_msg.encode({
      body = bson.document({ { "ok", 1 } }),
      direction = "response",
      request_id = 91,
      response_to = 42,
    }))
    local provider_failure = errors.new({
      category = errors.CATEGORY.INTERNAL,
      message = "provider failed",
    })
    local decompressions = 0
    local provider = {
      compressor_id = 2,
      compress = function()
        error("must not compress")
      end,
      decompress = function(_, input)
        decompressions = decompressions + 1

        if input == "fail" then
          return nil, provider_failure
        end

        return original:sub(17)
      end,
      name = "zlib",
    }
    local options = {
      compression = { zlib = provider },
      max_message_size = 4096,
    }
    local frames = {
      compressed_frame(original, 3, "unknown"),
      compressed_frame(original, 2, "mismatch", #original - 15),
      compressed_frame(original, 2, "truncated"):sub(1, 24),
      compressed_frame(original, 2, "oversized", 4096),
    }

    for _, frame in ipairs(frames) do
      local recovered, err = op_compressed.decode(frame, options)

      assert.is_nil(recovered)
      assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
    end

    local recovered, err = op_compressed.decode(
      compressed_frame(original, 2, "fail"),
      options
    )

    assert.is_nil(recovered)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
    assert.are.equal(provider_failure, err.cause)
    assert.are.equal(2, decompressions)
  end)

  it("accepts a compressed initial hello before compressor selection", function()
    local original_body
    local request
    local connection = { closed = false }
    local provider = {
      compressor_id = 2,
      compress = function()
        error("must not compress")
      end,
      decompress = function(_, input)
        assert.are.equal("compressed hello", input)
        return original_body
      end,
      name = "zlib",
    }

    function connection.write_all(_, bytes)
      request = assert(op_msg.decode(bytes, { direction = "request" }))
      return true
    end

    function connection.read_frame()
      local original = assert(op_msg.encode({
        body = bson.document({
          { "ok", 1 },
          { "isWritablePrimary", true },
          { "maxWireVersion", 25 },
        }),
        direction = "response",
        request_id = 91,
        response_to = request.request_id,
      }))

      original_body = original:sub(17)
      return compressed_frame(original, 2, "compressed hello")
    end

    function connection:close()
      self.closed = true
      return true
    end

    local commands = executor.new(connection, {
      compression = { zlib = provider },
    })
    local hello = assert(commands:hello())

    assert.is_true(hello.is_writable)
    assert.are.equal(25, hello.max_wire_version)
    assert.is_false(connection.closed)
  end)
end)
