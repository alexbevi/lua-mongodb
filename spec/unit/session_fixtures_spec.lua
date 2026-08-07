local session_runner = require("spec.support.session_runner")

describe("pinned session fixtures", function()
  it("runs server support, dirty pool, and causal write cases", function()
    assert.are.equal(2, session_runner.run(
      "sessions/tests/driver-sessions-server-support.json"
    ))
    assert.are.equal(6, session_runner.run(
      "sessions/tests/driver-sessions-dirty-session-errors.json"
    ))
    assert.are.equal(17, session_runner.run(
      "causal-consistency/tests/causal-consistency-write-commands.json"
    ))
    assert.are.equal(3, session_runner.run(
      "sessions/tests/implicit-sessions-default-causal-consistency.json"
    ))
  end)
end)
