local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")
local mongodb = require("mongodb")
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

local function upload_bucket(executor, identifier, options)
  local object_ids = {
    new = function()
      return identifier
    end,
  }
  local runtime = fake_runtime.new({ wall_time = 1234.567 })
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
end)
