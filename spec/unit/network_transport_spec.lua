local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local transport = require("mongodb.network.transport")

describe("exact coroutine network transport", function()
  it("connects and completes partial reads and writes", function()
    local runtime = fake_runtime.new()
    local socket = runtime.socket:new({ max_write = 2, reads = { "a", "bc" } })

    runtime:queue_connect(socket)

    local connection = assert(transport.connect(runtime, "localhost", 27017, {}))

    assert.are.equal("abc", assert(connection:read_exact(3)))
    assert.is_true(connection:write_all("hello"))
    assert.are.same({ "he", "ll", "o" }, socket:writes())
    assert.is_true(connection:close())
    assert.is_false(connection:close())
  end)

  it("keeps cancellation, timeout, and EOF failures distinct", function()
    local runtime = fake_runtime.new({ now = 5 })
    local cancelled = runtime.cancellation.new()
    local socket = runtime.socket:new({ reads = { "" } })

    local value, err = transport.connect(runtime, "localhost", 27017, { deadline = 5 })
    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))

    cancelled:cancel("stop")
    value, err = transport.connect(runtime, "localhost", 27017, {
      cancellation = cancelled,
    })
    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))

    runtime:queue_connect(socket)
    local connection = assert(transport.connect(runtime, "localhost", 27017, {}))

    value, err = connection:write_all("x", 5)
    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))

    value, err = connection:write_all("x", nil, cancelled)
    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))

    value, err = connection:read_exact(1, 5)
    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.TIMEOUT))

    value, err = connection:read_exact(1)
    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
  end)

  it("reads a length-prefixed frame without trusting an oversized header", function()
    local runtime = fake_runtime.new()
    local frame = string.pack("<i4", 16) .. string.rep("x", 12)
    local socket = runtime.socket:new({
      reads = { frame:sub(1, 2), frame:sub(3, 7), frame:sub(8) },
    })

    runtime:queue_connect(socket)
    local connection = assert(transport.connect(runtime, "localhost", 27017, {}))

    assert.are.equal(frame, assert(connection:read_frame(32)))

    socket:push_read(string.pack("<i4", 33))
    local value, err = connection:read_frame(32)

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
  end)
end)
