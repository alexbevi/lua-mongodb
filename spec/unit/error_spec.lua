local errors = require("mongodb.error")

describe("structured errors", function()
  it("exposes validated operational fields", function()
    local err = errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "connection closed",
      code = 89,
      code_name = "NetworkTimeout",
      server = "db.example:27017",
      retryable = true,
      timeout = true,
      details = { phase = "read" },
    })

    assert.is_true(errors.is(err))
    assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
    assert.are.equal("network", err.category)
    assert.are.equal("connection closed", err.message)
    assert.are.equal(89, err.code)
    assert.are.equal("NetworkTimeout", err.code_name)
    assert.are.equal("db.example:27017", err.server)
    assert.is_true(err.retryable)
    assert.is_true(err.timeout)
    assert.are.equal("read", err.details.phase)
  end)

  it("copies, deduplicates, and exposes labels", function()
    local labels = { "RetryableWriteError", "RetryableWriteError", "TransientTransactionError" }
    local err = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "command failed",
      labels = labels,
    })

    labels[1] = "changed"

    assert.are.equal(2, #err.labels)
    assert.are.equal("RetryableWriteError", err.labels[1])
    assert.are.equal("TransientTransactionError", err.labels[2])
    assert.is_true(err:has_label("RetryableWriteError"))
    assert.is_true(errors.has_label(err, "TransientTransactionError"))
    assert.is_false(err:has_label("UnknownError"))
  end)

  it("preserves structured causal chains", function()
    local cause = errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "socket closed",
    })
    local err = errors.new({
      category = errors.CATEGORY.TIMEOUT,
      message = "operation timed out",
      cause = cause,
    })

    assert.are.equal(cause, err.cause)
    assert.is_true(err.timeout)
    assert.is_true(err:is_category(errors.CATEGORY.TIMEOUT))
  end)

  it("keeps errors, labels, details, and categories immutable", function()
    local err = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "command failed",
      labels = { "RetryableWriteError" },
      details = { response = { ok = 0 } },
    })

    assert.has_error(function()
      err.message = "changed"
    end, "structured errors are immutable")
    assert.has_error(function()
      err.labels[1] = "changed"
    end, "structured error values are immutable")
    assert.has_error(function()
      err.details.response.ok = 1
    end, "structured error values are immutable")
    assert.has_error(function()
      errors.CATEGORY.SERVER = "changed"
    end, "structured error values are immutable")
  end)

  it("adds and removes labels without mutating the original", function()
    local original = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "command failed",
    })
    local added = errors.with_label(original, "RetryableWriteError")
    local removed = errors.without_label(added, "RetryableWriteError")

    assert.is_false(original:has_label("RetryableWriteError"))
    assert.is_true(added:has_label("RetryableWriteError"))
    assert.is_false(removed:has_label("RetryableWriteError"))
  end)

  it("formats stable, non-detail diagnostic strings", function()
    local err = errors.new({
      category = errors.CATEGORY.SERVER,
      message = "operation failed",
      code = 50,
      code_name = "MaxTimeMSExpired",
      server = "db.example:27017",
      details = { secret = "must not be formatted" },
    })

    assert.are.equal(
      "server: operation failed (code 50: MaxTimeMSExpired) [server db.example:27017]",
      tostring(err)
    )
  end)

  it("rejects constructor misuse as programmer errors", function()
    assert.has_error(function()
      errors.new({ message = "missing category" })
    end, "category must be a known error category")
    assert.has_error(function()
      errors.new({ category = errors.CATEGORY.NETWORK, message = "" })
    end, "message must be a non-empty string")
    assert.has_error(function()
      errors.new({
        category = errors.CATEGORY.NETWORK,
        message = "invalid cause",
        cause = "socket error",
      })
    end, "cause must be a structured error")
    assert.has_error(function()
      errors.new({
        category = errors.CATEGORY.NETWORK,
        message = "unknown option",
        typo = true,
      })
    end, "unknown error option: typo")
  end)

  it("recognizes non-errors without raising", function()
    assert.is_false(errors.is(nil))
    assert.is_false(errors.is("network failure"))
    assert.is_false(errors.has_label({}, "RetryableWriteError"))
  end)
end)
