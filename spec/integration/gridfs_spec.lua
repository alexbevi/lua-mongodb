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

describe("GridFS streams over OP_MSG", function()
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

  it("writes ordered chunks before the files document", function()
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

      assert.are.equal("fs.files", find.body:get("find"))
      send_response(peer, find, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "assets.fs.files" },
          { "firstBatch", bson.array({
            bson.document({ { "_id", "existing" } }),
          }) },
        }) },
      }))

      for number, data in ipairs({ "abcd", "efgh", "ij" }) do
        local insert = receive_frame(peer)
        local chunk = insert.body:get("documents"):get(1)

        assert.are.equal("fs.chunks", insert.body:get("insert"))
        assert.are.equal("caller-file-id", chunk:get("files_id"))
        assert.are.equal(number - 1, chunk:get("n"):to_number())
        assert.are.equal(bson.binary(data), chunk:get("data"))
        send_response(peer, insert, bson.document({ { "ok", 1 }, { "n", 1 } }))
      end

      local insert = receive_frame(peer)
      local file = insert.body:get("documents"):get(1)

      assert.are.equal("fs.files", insert.body:get("insert"))
      assert.are.equal("caller-file-id", file:get("_id"))
      assert.are.equal(10, file:get("length"):to_number())
      assert.are.equal(4, file:get("chunkSize"):to_number())
      assert.are.equal("chunks.txt", file:get("filename"))
      assert.are.equal("text", file:get("metadata"):get("kind"))
      assert.is_nil(file:get("md5"))
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
        local upload = assert(bucket:open_upload_stream_with_id(
          "caller-file-id",
          "chunks.txt",
          {
            chunk_size_bytes = 4,
            metadata = bson.document({ { "kind", "text" } }),
          }
        ))

        assert.is_true(assert(upload:write("abcdefghij")))
        assert.is_true(assert(upload:close()))
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("deletes upload documents when aborting", function()
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

      send_response(peer, find, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "assets.fs.files" },
          { "firstBatch", bson.array({
            bson.document({ { "_id", "existing" } }),
          }) },
        }) },
      }))

      local chunk_insert = receive_frame(peer)

      assert.are.equal("fs.chunks", chunk_insert.body:get("insert"))
      send_response(peer, chunk_insert, bson.document({ { "ok", 1 }, { "n", 1 } }))

      local chunks_delete = receive_frame(peer)
      local chunks_filter = chunks_delete.body:get("deletes"):get(1):get("q")

      assert.are.equal("fs.chunks", chunks_delete.body:get("delete"))
      assert.are.equal("abort-id", chunks_filter:get("files_id"))
      send_response(peer, chunks_delete, bson.document({ { "ok", 1 }, { "n", 1 } }))

      local files_delete = receive_frame(peer)
      local files_filter = files_delete.body:get("deletes"):get(1):get("q")

      assert.are.equal("fs.files", files_delete.body:get("delete"))
      assert.are.equal("abort-id", files_filter:get("_id"))
      send_response(peer, files_delete, bson.document({ { "ok", 1 }, { "n", 0 } }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/assets",
          { runtime = mongodb.runtime.copas() }
        ))
        local upload = assert(assert(client:database():gridfs_bucket())
          :open_upload_stream_with_id("abort-id", "aborted", {
            chunk_size_bytes = 4,
          }))

        assert.is_true(assert(upload:write("abcd")))
        assert.is_true(assert(upload:abort()))
        assert.is_true(upload.aborted)
        assert.is_true(upload.closed)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("reads validated chunks through a bounded download stream", function()
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

      local files_find = receive_frame(peer)

      assert.are.equal("fs.files", files_find.body:get("find"))
      assert.are.equal("download-id", files_find.body:get("filter"):get("_id"))
      send_response(peer, files_find, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "assets.fs.files" },
          { "firstBatch", bson.array({
            bson.document({
              { "_id", "download-id" },
              { "length", bson.int64(5) },
              { "chunkSize", 4 },
              { "filename", "letters.txt" },
            }),
          }) },
        }) },
      }))

      local chunks_find = receive_frame(peer)

      assert.are.equal("fs.chunks", chunks_find.body:get("find"))
      assert.are.equal(
        "download-id",
        chunks_find.body:get("filter"):get("files_id")
      )
      assert.are.equal(1, chunks_find.body:get("sort"):get("n"):to_number())
      send_response(peer, chunks_find, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "assets.fs.chunks" },
          { "firstBatch", bson.array({
            bson.document({
              { "files_id", "download-id" },
              { "n", 0 },
              { "data", bson.binary("abcd") },
            }),
            bson.document({
              { "files_id", "download-id" },
              { "n", 1 },
              { "data", bson.binary("e") },
            }),
          }) },
        }) },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/assets",
          { runtime = mongodb.runtime.copas() }
        ))
        local download = assert(assert(client:database():gridfs_bucket())
          :open_download_stream("download-id"))

        assert.are.equal("ab", assert(download:read(2)))
        assert.are.equal("cde", assert(download:read()))
        assert.is_true(assert(download:close()))
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("copies validated downloads into caller-owned destinations", function()
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

      local files_find = receive_frame(peer)

      assert.are.equal("fs.files", files_find.body:get("find"))
      send_response(peer, files_find, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "assets.fs.files" },
          { "firstBatch", bson.array({
            bson.document({
              { "_id", "copy-id" },
              { "length", 5 },
              { "chunkSize", 4 },
            }),
          }) },
        }) },
      }))

      local chunks_find = receive_frame(peer)

      assert.are.equal("fs.chunks", chunks_find.body:get("find"))
      send_response(peer, chunks_find, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "assets.fs.chunks" },
          { "firstBatch", bson.array({
            bson.document({
              { "files_id", "copy-id" },
              { "n", 0 },
              { "data", bson.binary("abcd") },
            }),
            bson.document({
              { "files_id", "copy-id" },
              { "n", 1 },
              { "data", bson.binary("e") },
            }),
          }) },
        }) },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/assets",
          { runtime = mongodb.runtime.copas() }
        ))
        local bucket = assert(client:database():gridfs_bucket())
        local destination = {
          bytes = {},
          closed = false,
          close = function(self)
            self.closed = true
          end,
          write = function(self, data)
            self.bytes[#self.bytes + 1] = data
            return true
          end,
        }

        assert.is_true(assert(bucket:download_to_stream(
          "copy-id",
          destination
        )))
        assert.are.equal("abcde", table.concat(destination.bytes))
        assert.is_false(destination.closed)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("copies selected filename revisions into caller-owned destinations", function()
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

      local files_find = receive_frame(peer)

      assert.are.equal("fs.files", files_find.body:get("find"))
      assert.are.equal(
        "report",
        files_find.body:get("filter"):get("filename")
      )
      assert.are.equal(
        1,
        files_find.body:get("sort"):get("uploadDate"):to_number()
      )
      assert.are.equal(1, files_find.body:get("skip"):to_number())
      send_response(peer, files_find, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "assets.fs.files" },
          { "firstBatch", bson.array({
            bson.document({
              { "_id", "named-copy-id" },
              { "length", 5 },
              { "chunkSize", 4 },
              { "filename", "report" },
            }),
          }) },
        }) },
      }))

      local chunks_find = receive_frame(peer)

      assert.are.equal("fs.chunks", chunks_find.body:get("find"))
      send_response(peer, chunks_find, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "assets.fs.chunks" },
          { "firstBatch", bson.array({
            bson.document({
              { "files_id", "named-copy-id" },
              { "n", 0 },
              { "data", bson.binary("abcd") },
            }),
            bson.document({
              { "files_id", "named-copy-id" },
              { "n", 1 },
              { "data", bson.binary("e") },
            }),
          }) },
        }) },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/assets",
          { runtime = mongodb.runtime.copas() }
        ))
        local bucket = assert(client:database():gridfs_bucket())
        local destination = {
          bytes = {},
          closed = false,
          close = function(self)
            self.closed = true
          end,
          write = function(self, data)
            self.bytes[#self.bytes + 1] = data
            return true
          end,
        }

        assert.is_true(assert(bucket:download_to_stream_by_name(
          "report",
          destination,
          { revision = 1 }
        )))
        assert.are.equal("abcde", table.concat(destination.bytes))
        assert.is_false(destination.closed)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("deletes files documents before their chunks", function()
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

      local files_delete = receive_frame(peer)

      assert.are.equal("fs.files", files_delete.body:get("delete"))
      assert.are.equal(
        "delete-id",
        files_delete.body:get("deletes"):get(1):get("q"):get("_id")
      )
      send_response(peer, files_delete, bson.document({
        { "ok", 1 },
        { "n", 1 },
      }))

      local chunks_delete = receive_frame(peer)

      assert.are.equal("fs.chunks", chunks_delete.body:get("delete"))
      assert.are.equal(
        "delete-id",
        chunks_delete.body:get("deletes"):get(1):get("q"):get("files_id")
      )
      send_response(peer, chunks_delete, bson.document({
        { "ok", 1 },
        { "n", 2 },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/assets",
          { runtime = mongodb.runtime.copas() }
        ))
        local bucket = assert(client:database():gridfs_bucket())

        assert.is_true(assert(bucket:delete("delete-id")))
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("deletes matching filename revisions before only their chunks", function()
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

      local files_find = receive_frame(peer)

      assert.are.equal("fs.files", files_find.body:get("find"))
      assert.are.equal("report", files_find.body:get("filter"):get("filename"))
      send_response(peer, files_find, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "assets.fs.files" },
          { "firstBatch", bson.array({
            bson.document({ { "_id", "revision-a" } }),
            bson.document({ { "_id", "revision-b" } }),
          }) },
        }) },
      }))

      local files_delete = receive_frame(peer)
      local file_ids = files_delete.body:get("deletes"):get(1):get("q")
        :get("_id"):get("$in")

      assert.are.equal("fs.files", files_delete.body:get("delete"))
      assert.are.equal("revision-a", file_ids:get(1))
      assert.are.equal("revision-b", file_ids:get(2))
      send_response(peer, files_delete, bson.document({
        { "ok", 1 },
        { "n", 2 },
      }))

      local chunks_delete = receive_frame(peer)
      local chunk_ids = chunks_delete.body:get("deletes"):get(1):get("q")
        :get("files_id"):get("$in")

      assert.are.equal("fs.chunks", chunks_delete.body:get("delete"))
      assert.are.equal("revision-a", chunk_ids:get(1))
      assert.are.equal("revision-b", chunk_ids:get(2))
      send_response(peer, chunks_delete, bson.document({
        { "ok", 1 },
        { "n", 3 },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/assets",
          { runtime = mongodb.runtime.copas() }
        ))
        local bucket = assert(client:database():gridfs_bucket())

        assert.is_true(assert(bucket:delete_by_name("report")))
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("finds matching files with GridFS options over OP_MSG", function()
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

      assert.are.equal("fs.files", find.body:get("find"))
      assert.are.equal("report", find.body:get("filter"):get("filename"))
      assert.is_true(find.body:get("allowDiskUse"))
      assert.are.equal(2, find.body:get("batchSize"):to_number())
      assert.are.equal(3, find.body:get("limit"):to_number())
      assert.are.equal(250, find.body:get("maxTimeMS"):to_number())
      assert.is_true(find.body:get("noCursorTimeout"))
      assert.are.equal(1, find.body:get("skip"):to_number())
      assert.are.equal(-1, find.body:get("sort"):get("uploadDate"):to_number())
      send_response(peer, find, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "assets.fs.files" },
          { "firstBatch", bson.array({
            bson.document({ { "_id", "file-a" } }),
            bson.document({ { "_id", "file-b" } }),
          }) },
        }) },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/assets",
          { runtime = mongodb.runtime.copas() }
        ))
        local bucket = assert(client:database():gridfs_bucket())
        local cursor = assert(bucket:find(
          bson.document({ { "filename", "report" } }),
          {
            allow_disk_use = true,
            batch_size = 2,
            limit = 3,
            max_time_ms = 250,
            no_cursor_timeout = true,
            skip = 1,
            sort = bson.document({ { "uploadDate", -1 } }),
          }
        ))

        assert.are.equal("file-a", assert(cursor:next()):get("_id"))
        assert.are.equal("file-b", assert(cursor:next()):get("_id"))
        assert.is_nil(cursor:next())
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("renames one files document and reports a missing id", function()
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

      for index, expected_id in ipairs({ "rename-id", "missing-id" }) do
        local update = receive_frame(peer)
        local model = update.body:get("updates"):get(1)

        assert.are.equal("fs.files", update.body:get("update"))
        assert.are.equal(expected_id, model:get("q"):get("_id"))
        assert.are.equal(
          "renamed.txt",
          model:get("u"):get("$set"):get("filename")
        )
        assert.are.same({ "$set" }, model:get("u"):keys())
        send_response(peer, update, bson.document({
          { "ok", 1 },
          { "n", index == 1 and 1 or 0 },
          { "nModified", index == 1 and 1 or 0 },
        }))
      end

      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/assets",
          { runtime = mongodb.runtime.copas() }
        ))
        local bucket = assert(client:database():gridfs_bucket())

        assert.is_true(assert(bucket:rename("rename-id", "renamed.txt")))
        local renamed, err = bucket:rename("missing-id", "renamed.txt")

        assert.is_nil(renamed)
        assert.are.equal("file_not_found", err.details.gridfs)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)

  it("renames every filename revision and reports a missing filename", function()
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

      for index, expected_filename in ipairs({ "report", "missing" }) do
        local update = receive_frame(peer)
        local model = update.body:get("updates"):get(1)

        assert.are.equal("fs.files", update.body:get("update"))
        assert.are.equal(expected_filename, model:get("q"):get("filename"))
        assert.is_true(model:get("multi"))
        assert.are.equal(
          "archive",
          model:get("u"):get("$set"):get("filename")
        )
        assert.are.same({ "$set" }, model:get("u"):keys())
        send_response(peer, update, bson.document({
          { "ok", 1 },
          { "n", index == 1 and 3 or 0 },
          { "nModified", index == 1 and 3 or 0 },
        }))
      end

      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/assets",
          { runtime = mongodb.runtime.copas() }
        ))
        local bucket = assert(client:database():gridfs_bucket())

        assert.is_true(assert(bucket:rename_by_name("report", "archive")))
        local renamed, err = bucket:rename_by_name("missing", "archive")

        assert.is_nil(renamed)
        assert.are.equal("file_not_found", err.details.gridfs)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
