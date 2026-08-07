local config_runner = require("spec.support.config_runner")

describe("pinned configuration fixtures", function()
  it("runs every applicable URI-options case", function()
    assert.are.equal(114, config_runner.run_uri_options())
  end)

  it("runs every read and write concern configuration case", function()
    assert.are.equal(38, config_runner.run_read_write_concern())
  end)
end)
