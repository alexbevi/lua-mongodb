local stress = require("spec.quality.stress")

describe("deterministic quality stress", function()
  it("replays every state-machine decision from its seed", function()
    local first = stress.run_seed(8675309, 2)
    local replay = stress.run_seed(8675309, 2)
    local other = stress.run_seed(8675310, 2)

    assert.are.same(first, replay)
    assert.are_not.equal(first.digest, other.digest)
    assert.are.equal(32, first.steps)
  end)
end)
