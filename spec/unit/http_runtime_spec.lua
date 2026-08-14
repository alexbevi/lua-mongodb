local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local http_runtime = require("mongodb.runtime.http")

describe("runtime HTTP adapter", function()
  it("uses socket and TLS adapters for bounded HTTPS requests", function()
    local runtime = fake_runtime.new()
    local socket = runtime.socket:new({
      max_write = 17,
      reads = {
        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n",
        "Content-Type: application/json\r\n\r\nbody",
      },
    })

    runtime:queue_connect(socket)
    runtime.http = http_runtime.new(runtime)

    local response = assert(runtime.http:request({
      body = "data",
      headers = { accept = "application/json" },
      method = "POST",
      url = "https://sts.amazonaws.com/path?query=1",
    }))

    assert.are.equal(200, response.status)
    assert.are.equal("body", response.body)
    assert.are.equal("application/json", response.headers["content-type"])
    assert.are.equal("sts.amazonaws.com", runtime.calls.connect[1].host)
    assert.are.equal(443, runtime.calls.connect[1].port)
    assert.are.equal("sts.amazonaws.com", runtime.calls.tls[1].options.server_name)
    assert.are.equal(table.concat({
      "POST /path?query=1 HTTP/1.1",
      "host: sts.amazonaws.com",
      "connection: close",
      "content-length: 4",
      "accept: application/json",
      "",
      "data",
    }, "\r\n"), table.concat(socket:writes()))
  end)

  it("decodes chunked responses and rejects ambiguous framing", function()
    local runtime = fake_runtime.new()
    local chunked = runtime.socket:new({ reads = {
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
      "4;name=value\r\nbody\r\n0\r\nX-Trace: done\r\n\r\n",
    } })

    runtime:queue_connect(chunked)
    runtime.http = http_runtime.new(runtime)

    assert.are.equal("body", assert(runtime.http:request({
      url = "http://metadata.test/",
    })).body)

    local ambiguous = runtime.socket:new({ reads = {
      "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n"
        .. "Transfer-Encoding: chunked\r\n\r\nbody",
    } })

    runtime:queue_connect(ambiguous)

    local response, err = runtime.http:request({
      url = "http://metadata.test/",
    })

    assert.is_nil(response)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
  end)
end)
