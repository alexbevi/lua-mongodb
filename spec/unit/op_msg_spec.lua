local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local op_msg = require("mongodb.wire.op_msg")

describe("OP_MSG framing", function()
  it("encodes golden kind-0 and kind-1 sections and decodes them in any order", function()
    local ids = op_msg.request_ids(42)
    local body = bson.document({ { "insert", "items" }, { "$db", "app" } })
    local document = bson.document({ { "name", "Ada" } })
    local options = {
      body = body,
      request_id = ids:next(),
      sequences = { { documents = { document }, identifier = "documents" } },
    }
    local bytes = assert(op_msg.encode(options))
    local body_bytes = assert(bson.encode(body))
    local document_bytes = assert(bson.encode(document))
    local sequence_size = 4 + #"documents" + 1 + #document_bytes
    local expected = string.pack("<i4i4i4i4I4B", #bytes, 42, 0, 2013, 0, 0)
      .. body_bytes
      .. string.pack("<Bi4", 1, sequence_size)
      .. "documents\0"
      .. document_bytes

    assert.are.equal(expected, bytes)
    assert.are.equal(43, ids:next())

    local measured = assert(op_msg.measure(options))
    assert.are.equal(#bytes, measured.message_size)
    assert.are.equal(#document_bytes, measured.max_document_size)

    local sequence_start = 22 + #body_bytes
    local reordered_payload = bytes:sub(17, 20)
      .. bytes:sub(sequence_start)
      .. bytes:sub(21, sequence_start - 1)
    local reordered = string.pack("<i4i4i4i4", #bytes, 42, 0, 2013)
      .. reordered_payload
    local decoded = assert(op_msg.decode(reordered, { direction = "request" }))
    assert.are.equal(42, decoded.request_id)
    assert.are.equal("insert", decoded.body:keys()[1])
    assert.are.equal("documents", decoded.sequences[1].identifier)
    assert.are.equal("Ada", decoded.sequences[1].documents[1]:get("name"))
  end)

  it("rejects checksums, malformed frames, and mismatched response IDs", function()
    local body = bson.document({ { "ok", 1 } })
    local bytes = assert(op_msg.encode({ body = body, request_id = 9, response_to = 7 }))
    local decoded, err = op_msg.decode(bytes, {
      direction = "response",
      expected_response_to = 8,
    })

    assert.is_nil(decoded)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))

    local checksum = bytes:sub(1, 16) .. string.pack("<I4", op_msg.FLAG.CHECKSUM_PRESENT)
      .. bytes:sub(21)
    decoded, err = op_msg.decode(checksum, { direction = "response" })
    assert.is_nil(decoded)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))

    local malformed = string.pack("<i4", #bytes + 1) .. bytes:sub(5)
    decoded, err = op_msg.decode(malformed, { direction = "response" })
    assert.is_nil(decoded)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
  end)

  it("enforces section uniqueness, required flags, and negotiated size limits", function()
    local body = bson.document({ { "ping", 1 }, { "$db", "admin" } })
    local body_bytes = assert(bson.encode(body))
    local bytes = assert(op_msg.encode({ body = body, request_id = 1 }))
    local invalid_required_flag = bytes:sub(1, 16) .. string.pack("<I4", 4)
      .. bytes:sub(21)
    local decoded, err = op_msg.decode(invalid_required_flag, { direction = "request" })

    assert.is_nil(decoded)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))

    local duplicate_payload = bytes:sub(17) .. "\0" .. body_bytes
    local duplicate = string.pack("<i4i4i4i4", 16 + #duplicate_payload, 1, 0, 2013)
      .. duplicate_payload
    decoded, err = op_msg.decode(duplicate, { direction = "request" })
    assert.is_nil(decoded)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))

    local encoded
    encoded, err = op_msg.encode({
      body = body,
      max_message_size = #bytes - 1,
      request_id = 1,
    })
    assert.is_nil(encoded)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))

    encoded, err = op_msg.encode({
      body = body,
      request_id = 1,
      sequences = {
        { documents = {}, identifier = "documents" },
        { documents = {}, identifier = "documents" },
      },
    })
    assert.is_nil(encoded)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
  end)
end)
