local bson = require("mongodb.bson")
local copas = require("copas")
local mongodb = require("mongodb")
local op_msg = require("mongodb.wire.op_msg")
local socket = require("socket")

local function receive_frame(client)
  local header = assert(client:receive(4))
  local size = string.unpack("<i4", header)
  return assert(op_msg.decode(header .. assert(client:receive(size - 4)), {
    direction = "request",
  }))
end

local function send_response(client, request, body)
  assert(client:send(assert(op_msg.encode({
    body = body,
    direction = "response",
    request_id = 9100 + request.request_id,
    response_to = request.request_id,
  }))))
end

local function empty_cursor(namespace)
  return bson.document({
    { "ok", 1 },
    { "cursor", bson.document({
      { "id", bson.int64(0) },
      { "ns", namespace },
      { "firstBatch", bson.array({}) },
    }) },
  })
end

describe("GridFS empty uploads over OP_MSG", function()
  it("creates required indexes before inserting the files document", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local find = receive_frame(peer)

      assert.are.equal("find", find.body:keys()[1])
      assert.are.equal("fs.files", find.body:get("find"))
      assert.are.equal(1, find.body:get("limit"):to_number())
      send_response(peer, find, empty_cursor("assets.fs.files"))

      local files_indexes = receive_frame(peer)

      assert.are.equal("fs.files", files_indexes.body:get("listIndexes"))
      send_response(peer, files_indexes, empty_cursor("assets.fs.files"))

      local create_files = receive_frame(peer)
      local files_model = create_files.body:get("indexes"):get(1)

      assert.are.equal("fs.files", create_files.body:get("createIndexes"))
      assert.are.equal("filename_1_uploadDate_1", files_model:get("name"))
      assert.is_nil(files_model:get("background"))
      send_response(peer, create_files, bson.document({ { "ok", 1 } }))

      local chunks_indexes = receive_frame(peer)

      assert.are.equal("fs.chunks", chunks_indexes.body:get("listIndexes"))
      send_response(peer, chunks_indexes, empty_cursor("assets.fs.chunks"))

      local create_chunks = receive_frame(peer)
      local chunks_model = create_chunks.body:get("indexes"):get(1)

      assert.are.equal("fs.chunks", create_chunks.body:get("createIndexes"))
      assert.are.equal("files_id_1_n_1", chunks_model:get("name"))
      assert.is_true(chunks_model:get("unique"))
      assert.is_nil(chunks_model:get("background"))
      send_response(peer, create_chunks, bson.document({ { "ok", 1 } }))

      local insert = receive_frame(peer)
      local file = insert.body:get("documents"):get(1)

      assert.are.equal("fs.files", insert.body:get("insert"))
      assert.are.equal(0, file:get("length"):to_number())
      assert.are.equal(255 * 1024, file:get("chunkSize"):to_number())
      assert.is_true(bson.is_tagged(file:get("_id"), "object_id"))
      assert.is_true(bson.is_tagged(file:get("uploadDate"), "datetime"))
      assert.are.equal("empty.txt", file:get("filename"))
      send_response(peer, insert, bson.document({ { "ok", 1 }, { "n", 1 } }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/assets",
          { runtime = mongodb.runtime.copas() }
        ))
        local bucket = assert(client:database():gridfs_bucket())
        local upload = assert(bucket:open_upload_stream("empty.txt"))

        assert.is_true(assert(upload:close()))
        assert.is_true(upload.closed)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
