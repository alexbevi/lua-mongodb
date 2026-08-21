local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")
local mongodb = require("mongodb")
local operation_timeout = require("mongodb.operation_timeout")
local fake_runtime = require("mongodb.runtime.fake")

local function database_with_options(options)
  local command_calls = 0
  local executor = {
    close = function()
      return true
    end,
    command = function()
      command_calls = command_calls + 1
      return bson.document({ { "ok", 1 } })
    end,
  }
  local config = assert(driver_options.normalize(nil, options))
  local database = assert(api.new_client(executor, config):database("assets"))

  return database, function()
    return command_calls
  end
end

local function cursor_response(namespace, documents)
  return bson.document({
    { "ok", 1 },
    { "cursor", bson.document({
      { "id", bson.int64(0) },
      { "ns", namespace },
      { "firstBatch", bson.array(documents) },
    }) },
  })
end

local function upload_bucket(executor, identifier, options, runtime)
  local object_ids = {
    new = function()
      return identifier
    end,
  }
  runtime = runtime or fake_runtime.new({ wall_time = 1234.567 })
  local config = assert(driver_options.normalize(nil, options or {}))
  local client = api.new_client(
    executor,
    config,
    nil,
    nil,
    object_ids,
    nil,
    runtime
  )

  return assert(client:database("assets"):gridfs_bucket())
end

describe("GridFS buckets", function()
  it("constructs the default bucket without database I/O", function()
    local database, command_calls = database_with_options({
      read_concern = { level = "majority" },
      read_preference = { mode = "secondary_preferred" },
      timeout_ms = 250,
      write_concern = { w = "majority" },
    })
    local bucket = assert(database:gridfs_bucket())

    assert.are.equal("fs", bucket.bucket_name)
    assert.are.equal(255 * 1024, bucket.chunk_size_bytes)
    assert.are.equal("assets.fs.files", bucket.files_collection.full_name)
    assert.are.equal("assets.fs.chunks", bucket.chunks_collection.full_name)
    assert.are.equal("majority", bucket.read_concern.level)
    assert.are.equal("secondary_preferred", bucket.read_preference.mode)
    assert.are.equal(250, bucket.timeout_ms)
    assert.are.equal("majority", bucket.write_concern.w)
    assert.are.equal(0, command_calls())
  end)

  it("constructs immutable custom buckets through the public factory", function()
    local database, command_calls = database_with_options({})
    local bucket = assert(mongodb.gridfs_bucket(database, {
      bucket_name = "media",
      chunk_size_bytes = 4096,
      disable_md5 = true,
      read_concern = { level = "local" },
      read_preference = { mode = "secondary" },
      timeout_ms = 500,
      write_concern = { journal = true, w = 2, w_timeout_ms = 100 },
    }))

    assert.are.equal("mongodb.gridfs_bucket", getmetatable(bucket))
    assert.are.equal("media", bucket.bucket_name)
    assert.are.equal(4096, bucket.chunk_size_bytes)
    assert.is_true(bucket.disable_md5)
    assert.are.equal("assets.media.files", bucket.files_collection.full_name)
    assert.are.equal("assets.media.chunks", bucket.chunks_collection.full_name)
    assert.are.equal("local", bucket.read_concern.level)
    assert.are.equal("secondary", bucket.read_preference.mode)
    assert.are.equal(500, bucket.timeout_ms)
    assert.are.equal(2, bucket.write_concern.w)
    assert.are.equal(0, command_calls())
    assert.has_error(function()
      bucket.bucket_name = "other"
    end, "MongoDB GridFS bucket handles are immutable")
  end)

  it("rejects invalid chunk sizes and unacknowledged writes", function()
    local database = database_with_options({})

    for _, chunk_size in ipairs({ 0, -1, 1.5, 0x80000000 }) do
      local bucket, err = database:gridfs_bucket({
        chunk_size_bytes = chunk_size,
      })

      assert.is_nil(bucket)
      assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
      assert.are.equal("chunk_size_bytes", err.details.option)
    end

    local bucket, err = database:gridfs_bucket({ write_concern = { w = 0 } })

    assert.is_nil(bucket)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("write_concern", err.details.option)
  end)

  it("validates public bucket options before database I/O", function()
    local database, command_calls = database_with_options({})
    local bucket, err = database:gridfs_bucket({ disable_md5 = "yes" })

    assert.is_nil(bucket)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("disable_md5", err.details.option)
    assert.has_error(function()
      database:gridfs_bucket({ unknown = true })
    end, "unknown GridFS bucket option: unknown")
    assert.has_error(function()
      mongodb.gridfs_bucket({}, {})
    end, "GridFS buckets require a MongoDB database handle")
    assert.are.equal(0, command_calls())
  end)

  it("closes empty uploads after lazily creating required indexes once", function()
    local generated_id = bson.object_id("010203041011121314151617")
    local caller_id = "caller-file-id"
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command, options)
        commands[#commands + 1] = { command = command, options = options }
        local name = command:keys()[1]

        if name == "find" then
          return cursor_response("assets.fs.files", {})
        elseif name == "listIndexes" then
          return cursor_response("assets." .. command:get("listIndexes"), {})
        end

        return bson.document({ { "ok", 1 }, { "n", 1 } })
      end,
    }
    local bucket = upload_bucket(executor, generated_id, {
      read_preference = { mode = "secondary" },
    })
    local upload = assert(bucket:open_upload_stream("empty.txt"))

    assert.are.equal(generated_id, upload.id)
    assert.is_false(upload.closed)
    assert.are.equal(0, #commands)
    assert.is_true(assert(upload:close()))
    assert.is_true(upload.closed)
    assert.are.equal(6, #commands)
    assert.are.equal("find", commands[1].command:keys()[1])
    assert.are.equal("primary", commands[1].options.read_preference.mode)
    assert.are.equal("createIndexes", commands[3].command:keys()[1])
    assert.are.same(
      { "filename", "uploadDate" },
      commands[3].command:get("indexes"):get(1):get("key"):keys()
    )
    assert.is_nil(commands[3].command:get("indexes"):get(1):get("unique"))
    assert.are.equal("createIndexes", commands[5].command:keys()[1])
    assert.are.same(
      { "files_id", "n" },
      commands[5].command:get("indexes"):get(1):get("key"):keys()
    )
    assert.is_true(commands[5].command:get("indexes"):get(1):get("unique"))

    local insert = commands[6].command
    local file = insert:get("documents"):get(1)

    assert.are.equal("fs.files", insert:get("insert"))
    assert.are.equal(generated_id, file:get("_id"))
    assert.are.equal(0, file:get("length"):to_number())
    assert.are.equal(255 * 1024, file:get("chunkSize"))
    assert.are.equal(bson.datetime(1234567), file:get("uploadDate"))
    assert.are.equal("empty.txt", file:get("filename"))

    local second = assert(bucket:open_upload_stream_with_id(
      caller_id,
      "second.txt"
    ))

    assert.are.equal(caller_id, second.id)
    assert.is_true(assert(second:close()))
    assert.are.equal(7, #commands)
    assert.are.equal("fs.files", commands[7].command:get("insert"))
    assert.is_true(assert(upload:close()))
    assert.are.equal(7, #commands)
  end)

  it("compares required index numeric types by value", function()
    local identifier = bson.object_id("010203041011121314151617")
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command
        local name = command:keys()[1]

        if name == "find" then
          return cursor_response("assets.fs.files", {})
        elseif name == "listIndexes" and command:get(name) == "fs.files" then
          return cursor_response("assets.fs.files", {
            bson.document({
              { "key", bson.document({
                { "filename", bson.int32(1) },
                { "uploadDate", bson.double(1) },
              }) },
            }),
          })
        elseif name == "listIndexes" then
          return cursor_response("assets.fs.chunks", {
            bson.document({
              { "key", bson.document({
                { "files_id", bson.int64(1) },
                { "n", bson.double(1) },
              }) },
            }),
          })
        end

        return bson.document({ { "ok", 1 }, { "n", 1 } })
      end,
    }
    local bucket = upload_bucket(executor, identifier)

    assert.is_true(assert(assert(bucket:open_upload_stream("empty")):close()))
    assert.are.equal(4, #commands)
    assert.are.equal("find", commands[1]:keys()[1])
    assert.are.equal("listIndexes", commands[2]:keys()[1])
    assert.are.equal("listIndexes", commands[3]:keys()[1])
    assert.are.equal("insert", commands[4]:keys()[1])
  end)

  it("keeps uploads open when index checks or file insertion fail", function()
    local identifier = bson.object_id("010203041011121314151617")
    local failure = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "write failed",
    })
    local index_commands = 0
    local index_executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        index_commands = index_commands + 1
        local name = command:keys()[1]

        if name == "find" then
          return cursor_response("assets.fs.files", {})
        elseif name == "listIndexes" then
          return cursor_response("assets.fs.files", {})
        end

        return nil, failure
      end,
    }
    local index_upload = assert(upload_bucket(
      index_executor,
      identifier
    ):open_upload_stream("empty"))
    local closed, err = index_upload:close()

    assert.is_nil(closed)
    assert.are.equal(failure, err)
    assert.is_false(index_upload.closed)
    assert.are.equal(3, index_commands)

    local insert_commands = 0
    local insert_executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        insert_commands = insert_commands + 1

        if command:keys()[1] == "find" then
          return cursor_response("assets.fs.files", {
            bson.document({ { "_id", identifier } }),
          })
        end

        return nil, failure
      end,
    }
    local insert_upload = assert(upload_bucket(
      insert_executor,
      identifier
    ):open_upload_stream("empty"))

    closed, err = insert_upload:close()
    assert.is_nil(closed)
    assert.are.equal(failure, err)
    assert.is_false(insert_upload.closed)
    assert.are.equal(2, insert_commands)
  end)

  it("writes exact and partial chunks before committing file metadata", function()
    local identifier = "custom-file-id"
    local metadata = bson.document({ { "contentType", "text/plain" } })
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command

        if command:keys()[1] == "find" then
          return cursor_response("assets.fs.files", {
            bson.document({ { "_id", "existing" } }),
          })
        end

        return bson.document({ { "ok", 1 }, { "n", 1 } })
      end,
    }
    local upload = assert(upload_bucket(
      executor,
      bson.object_id("010203041011121314151617")
    ):open_upload_stream_with_id(identifier, "chunks.txt", {
      chunk_size_bytes = 4,
      ignored = true,
      metadata = metadata,
    }))

    assert.is_true(assert(upload:write("ab")))
    assert.are.equal(0, #commands)
    assert.is_true(assert(upload:write("cdefgh")))
    assert.are.equal(3, #commands)
    assert.is_true(assert(upload:write("ij")))
    assert.are.equal(3, #commands)
    assert.is_true(assert(upload:close()))
    assert.are.equal(5, #commands)

    for number, data in ipairs({ "abcd", "efgh", "ij" }) do
      local insert = commands[number + 1]
      local chunk = insert:get("documents"):get(1)

      assert.are.equal("fs.chunks", insert:get("insert"))
      assert.are.equal(identifier, chunk:get("files_id"))
      assert.are.equal(number - 1, chunk:get("n"))
      assert.are.equal(bson.binary(data), chunk:get("data"))
    end

    local file_insert = commands[5]
    local file = file_insert:get("documents"):get(1)

    assert.are.equal("fs.files", file_insert:get("insert"))
    assert.are.equal(identifier, file:get("_id"))
    assert.are.equal(10, file:get("length"):to_number())
    assert.are.equal(4, file:get("chunkSize"))
    assert.are.equal("chunks.txt", file:get("filename"))
    assert.are.equal(metadata, file:get("metadata"))
    assert.is_nil(file:get("md5"))

    local written, err = upload:write("more")

    assert.is_nil(written)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(5, #commands)
  end)

  it("preserves chunk insert failures without cleaning up orphan chunks", function()
    local identifier = "failed-file-id"
    local failure = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "chunk write failed",
    })
    local commands = {}
    local chunk_inserts = 0
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command
        local name = command:keys()[1]

        if name == "find" then
          return cursor_response("assets.fs.files", {
            bson.document({ { "_id", "existing" } }),
          })
        elseif name == "insert" and command:get("insert") == "fs.chunks" then
          chunk_inserts = chunk_inserts + 1

          if chunk_inserts == 2 then
            return nil, failure
          end
        end

        return bson.document({ { "ok", 1 }, { "n", 1 } })
      end,
    }
    local upload = assert(upload_bucket(
      executor,
      bson.object_id("010203041011121314151617")
    ):open_upload_stream_with_id(identifier, "failed", {
      chunk_size_bytes = 4,
    }))
    local written, err = upload:write("abcdefgh")

    assert.is_nil(written)
    assert.are.equal(failure, err)
    assert.is_false(upload.closed)
    assert.are.equal(3, #commands)

    written, err = upload:write("more")
    assert.is_nil(written)
    assert.are.equal(failure, err)
    assert.are.equal(3, #commands)

    local closed
    closed, err = upload:close()
    assert.is_nil(closed)
    assert.are.equal(failure, err)
    assert.are.equal(3, #commands)

    for _, command in ipairs(commands) do
      local name = command:keys()[1]

      assert.is_not.equal("delete", name)
      assert.is_not.equal("filemd5", name)
    end
  end)

  it("aborts uploads by deleting stored chunks and closing the stream", function()
    local identifier = "aborted-file-id"
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command

        if command:keys()[1] == "find" then
          return cursor_response("assets.fs.files", {
            bson.document({ { "_id", "existing" } }),
          })
        end

        return bson.document({ { "ok", 1 }, { "n", 1 } })
      end,
    }
    local upload = assert(upload_bucket(
      executor,
      bson.object_id("010203041011121314151617")
    ):open_upload_stream_with_id(identifier, "aborted", {
      chunk_size_bytes = 4,
    }))

    assert.is_true(assert(upload:write("abcd")))
    assert.are.equal(2, #commands)
    assert.is_true(assert(upload:abort()))
    assert.is_true(upload.aborted)
    assert.is_true(upload.closed)
    assert.are.equal(4, #commands)

    local chunks_delete = commands[3]:get("deletes"):get(1)
    local files_delete = commands[4]:get("deletes"):get(1)

    assert.are.equal("fs.chunks", commands[3]:get("delete"))
    assert.are.equal(identifier, chunks_delete:get("q"):get("files_id"))
    assert.are.equal(0, chunks_delete:get("limit"))
    assert.are.equal("fs.files", commands[4]:get("delete"))
    assert.are.equal(identifier, files_delete:get("q"):get("_id"))
    assert.are.equal(1, files_delete:get("limit"))

    local value, err = upload:write("more")

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    value, err = upload:close()
    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(4, #commands)

    for _, command in ipairs(commands) do
      if command:keys()[1] == "insert" then
        assert.are.equal("fs.chunks", command:get("insert"))
      end
    end
  end)

  it("preserves abort cleanup failures in a terminal stream", function()
    local failure = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "cleanup failed",
    })
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command
        return nil, failure
      end,
    }
    local upload = assert(upload_bucket(
      executor,
      bson.object_id("010203041011121314151617")
    ):open_upload_stream_with_id("failed-abort", "failed"))
    local aborted, err = upload:abort()

    assert.is_nil(aborted)
    assert.are.equal(failure, err)
    assert.is_true(upload.aborted)
    assert.is_true(upload.closed)
    assert.are.equal(1, #commands)
    assert.are.equal("fs.chunks", commands[1]:get("delete"))

    aborted, err = upload:abort()
    assert.is_nil(aborted)
    assert.are.equal(failure, err)
    assert.are.equal(1, #commands)

    local closed
    closed, err = upload:close()
    assert.is_nil(closed)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal(1, #commands)
  end)

  it("uploads a readable source without closing it", function()
    local identifier = "readable-file-id"
    local commands = {}
    local reads = {}
    local source = {
      closed = false,
      parts = { "ab", "cd", "e" },
      read = function(self, size)
        reads[#reads + 1] = size
        return table.remove(self.parts, 1)
      end,
      close = function(self)
        self.closed = true
      end,
    }
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command

        if command:keys()[1] == "find" then
          return cursor_response("assets.fs.files", {
            bson.document({ { "_id", "existing" } }),
          })
        end

        return bson.document({ { "ok", 1 }, { "n", 1 } })
      end,
    }
    local bucket = upload_bucket(
      executor,
      bson.object_id("010203041011121314151617")
    )

    assert.is_true(assert(bucket:upload_from_stream_with_id(
      identifier,
      "readable.txt",
      source,
      { chunk_size_bytes = 4 }
    )))
    assert.is_false(source.closed)
    assert.are.same({ 4, 4, 4, 4 }, reads)
    assert.are.equal(4, #commands)
    assert.are.equal("find", commands[1]:keys()[1])
    assert.are.equal(
      bson.binary("abcd"),
      commands[2]:get("documents"):get(1):get("data")
    )
    assert.are.equal(
      bson.binary("e"),
      commands[3]:get("documents"):get(1):get("data")
    )
    assert.are.equal("readable.txt", commands[4]:get("documents"):get(1):get("filename"))
  end)

  it("returns generated ids for string sources under one timeout deadline", function()
    local identifier = bson.object_id("010203041011121314151617")
    local runtime = fake_runtime.new({ now = 5, wall_time = 1234.567 })
    local deadlines = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        deadlines[#deadlines + 1] = operation_timeout.current().deadline
        runtime:advance(0.005)

        if command:keys()[1] == "find" then
          return cursor_response("assets.fs.files", {
            bson.document({ { "_id", "existing" } }),
          })
        end

        return bson.document({ { "ok", 1 }, { "n", 1 } })
      end,
    }
    local bucket = upload_bucket(
      executor,
      identifier,
      { timeout_ms = 75 },
      runtime
    )

    assert.are.equal(identifier, assert(bucket:upload_from_stream(
      "string.txt",
      "abc",
      { chunk_size_bytes = 2, timeout_ms = 1000 }
    )))
    assert.are.equal(4, #deadlines)

    for _, deadline in ipairs(deadlines) do
      assert.is_true(math.abs(deadline - 6) < 0.000001)
    end
  end)

  it("aborts on readable source errors and preserves the original error", function()
    local failure = errors.new({
      category = errors.CATEGORY.CLIENT,
      message = "source failed",
    })
    local source = {
      closed = false,
      reads = 0,
      read = function(self)
        self.reads = self.reads + 1

        if self.reads == 1 then
          return "abcd"
        end

        error(failure, 0)
      end,
      close = function(self)
        self.closed = true
      end,
    }
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command

        if command:keys()[1] == "find" then
          return cursor_response("assets.fs.files", {
            bson.document({ { "_id", "existing" } }),
          })
        end

        return bson.document({ { "ok", 1 }, { "n", 1 } })
      end,
    }
    local bucket = upload_bucket(
      executor,
      bson.object_id("010203041011121314151617")
    )
    local uploaded, err = bucket:upload_from_stream_with_id(
      "failed-source-id",
      "failed.txt",
      source,
      { chunk_size_bytes = 4 }
    )

    assert.is_nil(uploaded)
    assert.are.equal(failure, err)
    assert.is_false(source.closed)
    assert.are.equal(4, #commands)
    assert.are.equal("insert", commands[2]:keys()[1])
    assert.are.equal("delete", commands[3]:keys()[1])
    assert.are.equal("fs.chunks", commands[3]:get("delete"))
    assert.are.equal("fs.files", commands[4]:get("delete"))
  end)

  it("reads zero-length downloads by id without querying chunks", function()
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command

        if command:get("find") == "fs.files" then
          return cursor_response("assets.fs.files", {
            bson.document({
              { "_id", "empty-file-id" },
              { "length", bson.int64(0) },
              { "chunkSize", bson.int64(4) },
              { "filename", "empty.txt" },
            }),
          })
        end

        error("zero-length downloads must not query GridFS chunks")
      end,
    }
    local bucket = upload_bucket(
      executor,
      bson.object_id("010203041011121314151617")
    )
    local download = assert(bucket:open_download_stream("empty-file-id"))

    assert.are.equal("empty-file-id", download.id)
    assert.are.equal(0, download.length)
    assert.are.equal(4, download.chunk_size_bytes)
    assert.are.equal("", assert(download:read()))
    assert.are.equal(0, download:tell())
    assert.is_true(assert(download:close()))
    assert.are.equal(1, #commands)
  end)

  it("supports bounded download reads and Lua seek positions", function()
    local runtime = fake_runtime.new({ now = 5 })
    local deadlines = {}
    local commands = {}
    local chunks = {
      bson.document({
        { "files_id", "file-id" },
        { "n", bson.int64(0) },
        { "data", bson.binary("abcd") },
      }),
      bson.document({
        { "files_id", "file-id" },
        { "n", bson.double(1) },
        { "data", bson.binary("e") },
      }),
    }
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command
        deadlines[#deadlines + 1] = operation_timeout.current().deadline
        runtime:advance(0.005)

        if command:get("find") == "fs.files" then
          return cursor_response("assets.fs.files", {
            bson.document({
              { "_id", "file-id" },
              { "length", bson.double(5) },
              { "chunkSize", bson.int64(4) },
              { "filename", "letters.txt" },
              { "metadata", bson.document({ { "kind", "text" } }) },
            }),
          })
        end

        local filter = command:get("filter")

        if bson.is_document(filter:get("n")) then
          return cursor_response("assets.fs.chunks", { chunks[2] })
        end

        return cursor_response("assets.fs.chunks", chunks)
      end,
    }
    local bucket = upload_bucket(
      executor,
      bson.object_id("010203041011121314151617"),
      { timeout_ms = 75 },
      runtime
    )
    local download = assert(bucket:open_download_stream(
      "file-id",
      { timeout_ms = 1000 }
    ))

    assert.are.equal("letters.txt", download.filename)
    assert.are.equal("text", download.metadata:get("kind"))
    assert.are.equal("ab", assert(download:read(2)))
    assert.are.equal(2, download:tell())
    assert.are.equal(4, assert(download:seek("set", 4)))
    assert.are.equal("e", assert(download:read(1)))
    assert.are.equal(1, assert(download:seek("end", -4)))
    assert.are.equal("bcd", assert(download:read(3)))
    assert.are.equal(5, assert(download:seek("end")))
    assert.are.equal("", assert(download:read()))
    assert.is_true(assert(download:close()))
    assert.are.equal(4, #commands)
    assert.are.equal(1, commands[3]:get("filter"):get("n"):get("$gte"))

    for _, deadline in ipairs(deadlines) do
      assert.is_true(math.abs(deadline - 6) < 0.000001)
    end
  end)

  it("copies downloads exactly without closing the destination", function()
    local runtime = fake_runtime.new({ now = 10 })
    local deadlines = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        deadlines[#deadlines + 1] = operation_timeout.current().deadline
        runtime:advance(0.005)

        if command:get("find") == "fs.files" then
          return cursor_response("assets.fs.files", {
            bson.document({
              { "_id", "copy-id" },
              { "length", 5 },
              { "chunkSize", 4 },
            }),
          })
        end

        return cursor_response("assets.fs.chunks", {
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
        })
      end,
    }
    local destination = {
      bytes = {},
      closed = false,
      close = function(self)
        self.closed = true
      end,
      write = function(self, data)
        deadlines[#deadlines + 1] = operation_timeout.current().deadline
        self.bytes[#self.bytes + 1] = data
        return true
      end,
    }
    local bucket = upload_bucket(
      executor,
      bson.object_id("010203041011121314151617"),
      nil,
      runtime
    )

    assert.is_true(assert(bucket:download_to_stream(
      "copy-id",
      destination,
      { timeout_ms = 1000 }
    )))
    assert.are.equal("abcde", table.concat(destination.bytes))
    assert.is_false(destination.closed)

    for _, deadline in ipairs(deadlines) do
      assert.is_true(math.abs(deadline - 11) < 0.000001)
    end
  end)

  it("preserves the first download, destination, or close error", function()
    local read_failure = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "download read failed",
    })
    local read_executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        if command:get("find") == "fs.files" then
          return cursor_response("assets.fs.files", {
            bson.document({
              { "_id", "read-failure" },
              { "length", 4 },
              { "chunkSize", 4 },
            }),
          })
        end

        return nil, read_failure
      end,
    }
    local untouched = {
      closed = false,
      close = function(self)
        self.closed = true
      end,
      write = function()
        error("failed reads must not write to the destination")
      end,
    }
    local copied, err = upload_bucket(
      read_executor,
      bson.object_id("010203041011121314151617")
    ):download_to_stream("read-failure", untouched)

    assert.is_nil(copied)
    assert.are.equal(read_failure, err)
    assert.is_false(untouched.closed)

    local write_failure = errors.new({
      category = errors.CATEGORY.CLIENT,
      message = "destination write failed",
    })
    local close_failure = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "download close failed",
    })
    local function failure_executor()
      return {
        close = function()
          return true
        end,
        command = function(_, _, command)
          if command:get("find") == "fs.files" then
            return cursor_response("assets.fs.files", {
              bson.document({
                { "_id", "copy-failure" },
                { "length", 4 },
                { "chunkSize", 4 },
              }),
            })
          elseif command:get("find") == "fs.chunks" then
            return bson.document({
              { "ok", 1 },
              { "cursor", bson.document({
                { "id", bson.int64(42) },
                { "ns", "assets.fs.chunks" },
                { "firstBatch", bson.array({
                  bson.document({
                    { "files_id", "copy-failure" },
                    { "n", 0 },
                    { "data", bson.binary("data") },
                  }),
                }) },
              }) },
            })
          end

          return nil, close_failure
        end,
      }
    end
    local rejected_destination = {
      closed = false,
      close = function(self)
        self.closed = true
      end,
      write = function()
        return nil, write_failure
      end,
    }

    copied, err = upload_bucket(
      failure_executor(),
      bson.object_id("010203041011121314151617")
    ):download_to_stream("copy-failure", rejected_destination)
    assert.is_nil(copied)
    assert.are.equal(write_failure, err)
    assert.is_false(rejected_destination.closed)

    local accepted_destination = {
      closed = false,
      close = function(self)
        self.closed = true
      end,
      write = function()
        return true
      end,
    }

    copied, err = upload_bucket(
      failure_executor(),
      bson.object_id("010203041011121314151617")
    ):download_to_stream("copy-failure", accepted_destination)
    assert.is_nil(copied)
    assert.are.equal(close_failure, err)
    assert.is_false(accepted_destination.closed)
  end)

  it("downloads the newest filename revision by default", function()
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command

        if command:get("find") == "fs.files" then
          return cursor_response("assets.fs.files", {
            bson.document({
              { "_id", "newest-id" },
              { "length", 1 },
              { "chunkSize", 4 },
              { "filename", "report" },
            }),
          })
        end

        return cursor_response("assets.fs.chunks", {
          bson.document({
            { "files_id", "newest-id" },
            { "n", 0 },
            { "data", bson.binary("z") },
          }),
        })
      end,
    }
    local bucket = upload_bucket(
      executor,
      bson.object_id("010203041011121314151617")
    )
    local download = assert(bucket:open_download_stream_by_name("report"))

    assert.are.equal("z", assert(download:read()))
    assert.is_true(assert(download:close()))
    assert.are.equal("report", commands[1]:get("filter"):get("filename"))
    assert.are.equal(-1, commands[1]:get("sort"):get("uploadDate"))
    assert.are.equal(0, commands[1]:get("skip"))
  end)

  it("selects positive and negative filename revisions", function()
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command

        return cursor_response("assets.fs.files", {
          bson.document({
            { "_id", "revision-" .. #commands },
            { "length", 0 },
            { "chunkSize", 4 },
            { "filename", "report" },
          }),
        })
      end,
    }
    local bucket = upload_bucket(
      executor,
      bson.object_id("010203041011121314151617")
    )
    local cases = {
      { revision = 0, sort = 1, skip = 0 },
      { revision = 1, sort = 1, skip = 1 },
      { revision = 2, sort = 1, skip = 2 },
      { revision = -2, sort = -1, skip = 1 },
      { revision = -1, sort = -1, skip = 0 },
    }

    for index, case in ipairs(cases) do
      local download = assert(bucket:open_download_stream_by_name(
        "report",
        { revision = case.revision }
      ))

      assert.are.equal("revision-" .. index, download.id)
      assert.is_true(assert(download:close()))
      assert.are.equal(
        case.sort,
        commands[index]:get("sort"):get("uploadDate")
      )
      assert.are.equal(case.skip, commands[index]:get("skip"))
    end
  end)

  it("distinguishes missing filenames from missing revisions", function()
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        local filename = command:get("filter"):get("filename")

        if filename == "report" and command:get("skip") == nil then
          return cursor_response("assets.fs.files", {
            bson.document({ { "_id", "existing" } }),
          })
        end

        return cursor_response("assets.fs.files", {})
      end,
    }
    local bucket = upload_bucket(
      executor,
      bson.object_id("010203041011121314151617")
    )
    local missing, missing_err = bucket:open_download_stream_by_name("absent")

    assert.is_nil(missing)
    assert.is_true(errors.is(missing_err, errors.CATEGORY.CLIENT))
    assert.are.equal("file_not_found", missing_err.details.gridfs)
    assert.are.equal("absent", missing_err.details.filename)

    local revision, revision_err = bucket:open_download_stream_by_name(
      "report",
      { revision = 999 }
    )

    assert.is_nil(revision)
    assert.is_true(errors.is(revision_err, errors.CATEGORY.CLIENT))
    assert.are.equal("revision_not_found", revision_err.details.gridfs)
    assert.are.equal("report", revision_err.details.filename)
    assert.are.equal(999, revision_err.details.revision)
  end)

  it("copies a selected filename revision without closing the destination", function()
    local runtime = fake_runtime.new({ now = 20 })
    local commands = {}
    local deadlines = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command
        deadlines[#deadlines + 1] = operation_timeout.current().deadline
        runtime:advance(0.005)

        if command:get("find") == "fs.files" then
          return cursor_response("assets.fs.files", {
            bson.document({
              { "_id", "named-copy-id" },
              { "length", 5 },
              { "chunkSize", 4 },
              { "filename", "report" },
            }),
          })
        end

        return cursor_response("assets.fs.chunks", {
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
        })
      end,
    }
    local destination = {
      bytes = {},
      closed = false,
      close = function(self)
        self.closed = true
      end,
      write = function(self, data)
        deadlines[#deadlines + 1] = operation_timeout.current().deadline
        self.bytes[#self.bytes + 1] = data
        return true
      end,
    }
    local bucket = upload_bucket(
      executor,
      bson.object_id("010203041011121314151617"),
      nil,
      runtime
    )

    assert.is_true(assert(bucket:download_to_stream_by_name(
      "report",
      destination,
      { revision = 1, timeout_ms = 1000 }
    )))
    assert.are.equal("abcde", table.concat(destination.bytes))
    assert.is_false(destination.closed)
    assert.are.equal(1, commands[1]:get("sort"):get("uploadDate"))
    assert.are.equal(1, commands[1]:get("skip"))

    for _, deadline in ipairs(deadlines) do
      assert.is_true(math.abs(deadline - 21) < 0.000001)
    end
  end)

  it("deletes a files document before its chunks under one deadline", function()
    local runtime = fake_runtime.new({ now = 30 })
    local commands = {}
    local deadlines = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command
        deadlines[#deadlines + 1] = operation_timeout.current().deadline
        runtime:advance(0.005)
        return bson.document({ { "ok", 1 }, { "n", 1 } })
      end,
    }
    local bucket = upload_bucket(
      executor,
      bson.object_id("010203041011121314151617"),
      nil,
      runtime
    )

    assert.is_true(assert(bucket:delete(
      "delete-id",
      { timeout_ms = 1000 }
    )))
    assert.are.equal("fs.files", commands[1]:get("delete"))
    assert.are.equal(
      "delete-id",
      commands[1]:get("deletes"):get(1):get("q"):get("_id")
    )
    assert.are.equal("fs.chunks", commands[2]:get("delete"))
    assert.are.equal(
      "delete-id",
      commands[2]:get("deletes"):get(1):get("q"):get("files_id")
    )

    for _, deadline in ipairs(deadlines) do
      assert.is_true(math.abs(deadline - 31) < 0.000001)
    end
  end)

  it("cleans orphan chunks before reporting a missing file", function()
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command
        return bson.document({ { "ok", 1 }, { "n", 0 } })
      end,
    }
    local bucket = upload_bucket(
      executor,
      bson.object_id("010203041011121314151617")
    )
    local deleted, err = bucket:delete("missing-id")

    assert.is_nil(deleted)
    assert.is_true(errors.is(err, errors.CATEGORY.CLIENT))
    assert.are.equal("file_not_found", err.details.gridfs)
    assert.are.equal("missing-id", err.details.id)
    assert.are.equal("fs.files", commands[1]:get("delete"))
    assert.are.equal("fs.chunks", commands[2]:get("delete"))
  end)

  it("deletes every filename revision before only their chunks", function()
    local commands = {}
    local executor = {
      close = function()
        return true
      end,
      command = function(_, _, command)
        commands[#commands + 1] = command

        if command:get("find") == "fs.files" then
          return cursor_response("assets.fs.files", {
            bson.document({ { "_id", "revision-a" } }),
            bson.document({ { "_id", "revision-b" } }),
          })
        end

        return bson.document({ { "ok", 1 }, { "n", 2 } })
      end,
    }
    local bucket = upload_bucket(
      executor,
      bson.object_id("010203041011121314151617")
    )

    assert.is_true(assert(bucket:delete_by_name("report")))
    assert.are.equal("report", commands[1]:get("filter"):get("filename"))
    assert.are.equal(1, commands[1]:get("projection"):get("_id"))
    assert.are.equal("fs.files", commands[2]:get("delete"))
    assert.are.equal("fs.chunks", commands[3]:get("delete"))

    local file_ids = commands[2]:get("deletes"):get(1):get("q")
      :get("_id"):get("$in")
    local chunk_ids = commands[3]:get("deletes"):get(1):get("q")
      :get("files_id"):get("$in")

    assert.are.equal("revision-a", file_ids:get(1))
    assert.are.equal("revision-b", file_ids:get(2))
    assert.are.equal("revision-a", chunk_ids:get(1))
    assert.are.equal("revision-b", chunk_ids:get(2))
  end)

  it("distinguishes missing files from corrupt required chunks", function()
    local function bucket_for(file, chunks)
      local executor = {
        close = function()
          return true
        end,
        command = function(_, _, command)
          if command:get("find") == "fs.files" then
            return cursor_response(
              "assets.fs.files",
              file and { file } or {}
            )
          end

          return cursor_response("assets.fs.chunks", chunks or {})
        end,
      }

      return upload_bucket(
        executor,
        bson.object_id("010203041011121314151617")
      )
    end

    local missing, missing_err = bucket_for(nil):open_download_stream("lost")

    assert.is_nil(missing)
    assert.is_true(errors.is(missing_err, errors.CATEGORY.CLIENT))
    assert.are.equal("file_not_found", missing_err.details.gridfs)

    local file = bson.document({
      { "_id", "broken" },
      { "length", bson.int64(8) },
      { "chunkSize", 4 },
    })
    local download = assert(bucket_for(file, {
      bson.document({
        { "files_id", "broken" },
        { "n", 0 },
        { "data", bson.binary("abcd") },
      }),
    }):open_download_stream("broken"))
    local bytes, corrupt_err = download:read()

    assert.is_nil(bytes)
    assert.is_true(errors.is(corrupt_err, errors.CATEGORY.CLIENT))
    assert.are.equal("corrupt_file", corrupt_err.details.gridfs)
    assert.are.equal(1, corrupt_err.details.chunk)
    assert.is_true(assert(download:close()))

    local malformed = assert(bucket_for(file, {
      bson.document({
        { "files_id", "broken" },
        { "n", 1 },
        { "data", bson.binary("abcd") },
      }),
    }):open_download_stream("broken"))
    local _, malformed_err = malformed:read(1)

    assert.are.equal("corrupt_file", malformed_err.details.gridfs)
    assert.are.equal(0, malformed_err.details.chunk)
    assert.are.equal(1, malformed_err.details.actual_chunk)
  end)
end)
