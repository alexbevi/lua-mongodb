local api = require("mongodb.api")
local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")
local mongodb = require("mongodb")

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
end)
