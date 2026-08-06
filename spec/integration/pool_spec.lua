local cmap_runner = require("spec.support.cmap_runner")

describe("CMAP connection establishment integration", function()
  it("runs every pinned establishment and maxConnecting fixture", function()
    local paths = cmap_runner.fixture_paths("integration")

    assert.are.equal(7, #paths)

    for _, path in ipairs(paths) do
      assert(cmap_runner.run(path, true))
    end
  end)
end)
