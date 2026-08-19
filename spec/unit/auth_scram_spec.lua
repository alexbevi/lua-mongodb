local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local scram = require("mongodb.auth.scram")
local saslprep = require("mongodb.auth.saslprep")
local fake_runtime = require("mongodb.runtime.fake")
local openssl = require("mongodb.runtime.openssl")

local ENTROPY = string.pack(
  ">I4I4I4I4I4I4I4I4",
  0x00010203,
  0x04050607,
  0x08090a0b,
  0x0c0d0e0f,
  0x10111213,
  0x14151617,
  0x18191a1b,
  0x1c1d1e1f
)
local NONCE = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
local SALT = "W22ZaJ0SNY7soEsUEjb6gQ=="

local function scripted_commands(responses)
  local commands = { calls = {}, responses = responses }

  function commands:command(database, command)
    self.calls[#self.calls + 1] = { command = command, database = database }
    return table.remove(self.responses, 1)
  end

  return commands
end

local function test_runtime(entropy)
  local runtime = fake_runtime.new({ entropy = entropy or ENTROPY })

  runtime.crypto = openssl.new().crypto
  return runtime
end

local function first_response(server_first)
  return bson.document({
    { "conversationId", 1 },
    { "payload", bson.binary(server_first) },
    { "done", false },
    { "ok", 1 },
  })
end

local function final_response(server_final, done)
  return bson.document({
    { "conversationId", 1 },
    { "payload", bson.binary(server_final) },
    { "done", done },
    { "ok", 1 },
  })
end

local function credentials(mechanism)
  return {
    mechanism = mechanism,
    password = "pencil",
    source = "admin",
    username = "user",
  }
end

local function hex(bytes)
  return (bytes:gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end))
end

describe("SCRAM authentication", function()
  it("provides digest, HMAC, PBKDF2, and entropy capabilities", function()
    local adapter = openssl.new()

    assert.are.equal(
      "900150983cd24fb0d6963f7d28e17f72",
      hex(assert(adapter.crypto:md5("abc")))
    )
    assert.are.equal(
      "a9993e364706816aba3e25717850c26c9cd0d89d",
      hex(assert(adapter.crypto:sha1("abc")))
    )
    assert.are.equal(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      hex(assert(adapter.crypto:sha256("abc")))
    )
    assert.are.equal(
      "de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9",
      hex(assert(adapter.crypto:hmac_sha1("key", "The quick brown fox jumps over the lazy dog")))
    )
    assert.are.equal(
      "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
      hex(assert(adapter.crypto:hmac_sha256("key", "The quick brown fox jumps over the lazy dog")))
    )
    assert.are.equal(
      "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
      hex(assert(adapter.crypto:hmac_sha256(
        string.rep("\170", 131),
        "Test Using Larger Than Block-Size Key - Hash Key First"
      )))
    )
    assert.are.equal(
      "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
      hex(assert(adapter.crypto:pbkdf2_sha256("password", "salt", 1, 32)))
    )
    assert.are.equal(32, #assert(adapter.entropy:bytes(32)))
  end)

  it("performs the normative SCRAM-SHA-256 conversation", function()
    local runtime = test_runtime()
    local server_first = "r=" .. NONCE .. "server-suffix,s=" .. SALT .. ",i=4096"
    local commands = scripted_commands({
      first_response(server_first),
      final_response("v=ULVJCzOWFs0L7wP6UkjMKgjZGBcBDyOfKFh3lKC0cXk=", true),
    })

    assert.is_true(scram.authenticate(commands, runtime, credentials("SCRAM-SHA-256")))

    local start = commands.calls[1].command
    local continue = commands.calls[2].command

    assert.are.equal("admin", commands.calls[1].database)
    assert.are.equal("SCRAM-SHA-256", start:get("mechanism"))
    assert.is_true(start:get("options"):get("skipEmptyExchange"))
    assert.are.equal(
      "n,,n=user,r=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
      start:get("payload").data
    )
    assert.are.equal(
      "c=biws,r=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
        .. "server-suffix,p=HZEmipSgzJfyX7B1oWa3JqRQhM7vHiB1kTo7N8H8UY8=",
      continue:get("payload").data
    )
  end)

  it("supports SCRAM-SHA-1 and reuses cached derived keys", function()
    local runtime = test_runtime(ENTROPY .. ENTROPY)
    local server_first = "r=" .. NONCE .. "server-suffix,s=" .. SALT .. ",i=4096"
    local responses = {}

    for _ = 1, 2 do
      responses[#responses + 1] = first_response(server_first)
      responses[#responses + 1] = final_response("v=foqRu+JHy2oRB4Rl/tcjjsLYuGA=", true)
    end

    local commands = scripted_commands(responses)
    local auth = credentials("SCRAM-SHA-1")
    local original_pbkdf2 = runtime.crypto.pbkdf2_sha1
    local derivations = 0

    runtime.crypto.pbkdf2_sha1 = function(provider, ...)
      derivations = derivations + 1
      return original_pbkdf2(provider, ...)
    end

    assert.is_true(scram.authenticate(commands, runtime, auth))
    assert.is_true(scram.authenticate(commands, runtime, auth))
    assert.are.equal(1, derivations)
    assert.are.equal(
      "c=biws,r=" .. NONCE
        .. "server-suffix,p=qUTa11FgAwZDny9tGIgXsckjKuU=",
      commands.calls[2].command:get("payload").data
    )
  end)

  it("rejects nonce and signature substitution without exposing secrets", function()
    local bad_nonce = scripted_commands({
      first_response("r=attacker,s=" .. SALT .. ",i=4096"),
    })
    local value, err = scram.authenticate(
      bad_nonce,
      test_runtime(),
      credentials("SCRAM-SHA-256")
    )

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal("SCRAM server returned an invalid nonce", err.message)

    local server_first = "r=" .. NONCE .. "server-suffix,s=" .. SALT .. ",i=4096"
    local bad_signature = scripted_commands({
      first_response(server_first),
      final_response("v=not-the-server-signature", true),
    })

    value, err = scram.authenticate(
      bad_signature,
      test_runtime(),
      credentials("SCRAM-SHA-256")
    )

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.is_nil(tostring(err):find("pencil", 1, true))
    assert.is_nil(tostring(err):find("not-the-server-signature", 1, true))
  end)

  it("sanitizes authentication command failures", function()
    local commands = {}

    function commands.command()
      return nil, errors.new({
        category = errors.CATEGORY.SERVER,
        details = {
          response = bson.document({ { "payload", bson.binary("pencil") } }),
        },
        message = "server reflected pencil",
      })
    end

    local value, err = scram.authenticate(
      commands,
      test_runtime(),
      credentials("SCRAM-SHA-256")
    )

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal("SCRAM authentication command failed", err.message)
    assert.is_nil(err.details)
    assert.is_nil(err.cause)
    assert.is_nil(tostring(err):find("pencil", 1, true))
  end)

  it("preserves retryable authentication handshake failures", function()
    local cases = {
      {
        error = errors.new({
          category = errors.CATEGORY.NETWORK,
          message = "connection closed",
        }),
        retryable = true,
      },
      {
        code = 91,
        error = errors.new({
          category = errors.CATEGORY.SERVER,
          code = 91,
          code_name = "ShutdownInProgress",
          message = "shutdown in progress",
        }),
      },
    }

    for _, case in ipairs(cases) do
      local commands = {}

      function commands.command()
        return nil, case.error
      end

      local value, err = scram.authenticate(
        commands,
        test_runtime(),
        credentials("SCRAM-SHA-256")
      )

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
      assert.are.equal(case.retryable == true, err:is_retryable())
      assert.are.equal(case.code, err.code)
      assert.are.equal("SCRAM authentication command failed", err.message)
    end
  end)

  it("finishes the legacy third empty exchange", function()
    local server_first = "r=" .. NONCE .. "server-suffix,s=" .. SALT .. ",i=4096"
    local commands = scripted_commands({
      first_response(server_first),
      final_response("v=ULVJCzOWFs0L7wP6UkjMKgjZGBcBDyOfKFh3lKC0cXk=", false),
      final_response("", true),
    })

    assert.is_true(scram.authenticate(
      commands,
      test_runtime(),
      credentials("SCRAM-SHA-256")
    ))
    assert.are.equal("", commands.calls[3].command:get("payload").data)
  end)

  it("normalizes passwords and rejects prohibited output", function()
    assert.are.equal("IX", assert(saslprep.prepare("I\u{00ad}X")))
    assert.are.equal("a", assert(saslprep.prepare("\u{00aa}")))
    assert.are.equal("IX", assert(saslprep.prepare("\u{2168}")))

    local value, err = saslprep.prepare("\u{0007}")

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))

    value, err = saslprep.prepare("\u{0627}1")

    assert.is_nil(value)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
  end)
end)
