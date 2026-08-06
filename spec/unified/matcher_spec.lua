local bson = require("mongodb.bson")
local fake_runtime = require("mongodb.runtime.fake")
local unified = require("mongodb.unified.runner")

local function load_fixture(path)
  local file = assert(io.open(path, "rb"))
  local contents = assert(file:read("a"))
  assert(file:close())
  return assert(bson.json.decode(contents))
end

local function meta_fixture(category, name)
  return load_fixture(
    "planning/specifications/source/unified-test-format/tests/"
      .. category .. "/" .. name .. ".json"
  )
end

local function find_operation(test)
  for _, operation in test:get("operations"):iter() do
    if operation:get("name") == "find" then
      return operation
    end
  end
end

local function find_document(runner, fixture, filter)
  local documents = fixture:get("initialData"):get(1):get("documents")

  for _, candidate in documents:iter() do
    if runner:match(filter, candidate) then
      return candidate
    end
  end
end

local FAILURE_REASONS = {
  ["matchAsDocument with non-matching filter"] = "values do not match",
  ["matchAsDocument evaluates special operators"] = "property existence does not match",
  ["matchAsDocument does not permit extra fields"] = "unexpected properties",
  ["matchAsDocument expects JSON object but given scalar"] = "expected an object",
  ["matchAsDocument expects JSON object but given array"] = "expected an object",
  ["matchAsDocument fails to decode Extended JSON"] = "could not parse match document",
  ["matchAsRoot with nested document does not match"] = "values do not match",
}

local function execute_find_match_cases(name, expected_to_match)
  local category = expected_to_match and "valid-pass" or "valid-fail"
  local fixture = meta_fixture(category, name)
  local runner = assert(unified.new({ runtime = fake_runtime.new() }))
  local executed = 0

  for _, test in fixture:get("tests"):iter() do
    local operation = assert(find_operation(test))
    local actual = assert(find_document(
      runner,
      fixture,
      operation:get("arguments"):get("filter")
    ))
    local ok, err = runner:match(operation:get("expectResult"), bson.array({ actual }))

    assert.are.equal(expected_to_match, ok == true, test:get("description"))

    if not expected_to_match then
      local reason = assert(FAILURE_REASONS[test:get("description")])
      assert.is_truthy(err.message:find(reason, 1, true), test:get("description"))
    end

    executed = executed + 1
  end

  return executed
end

describe("unified matcher meta-fixtures", function()
  it("executes every dedicated root and Extended JSON pass/fail case", function()
    local executed = 0
    executed = executed + execute_find_match_cases("operator-matchAsDocument", true)
    executed = executed + execute_find_match_cases("operator-matchAsRoot", true)
    executed = executed + execute_find_match_cases("operator-matchAsDocument", false)
    executed = executed + execute_find_match_cases("operator-matchAsRoot", false)

    assert.are.equal(14, executed)
  end)

  it("executes the dedicated flexible type and less-than-or-equal cases", function()
    local type_fixture = meta_fixture("valid-pass", "operator-type-number_alias")
    local runner = assert(unified.new({ runtime = fake_runtime.new() }))
    local executed = 0

    for _, test in type_fixture:get("tests"):iter() do
      local inserted = test:get("operations"):get(1):get("arguments"):get("document")
      local expected = assert(find_operation(test)):get("expectResult")
      assert(runner:match(expected, bson.array({ inserted })), test:get("description"))
      executed = executed + 1
    end

    local lte_fixture = meta_fixture("valid-pass", "operator-lte")
    local test = lte_fixture:get("tests"):get(1)
    local operation = test:get("operations"):get(1)
    local expected_command = test:get("expectEvents"):get(1):get("events")
      :get(1):get("commandStartedEvent"):get("command")
    local actual_command = bson.document({
      { "insert", "coll0" },
      { "documents", bson.array({ operation:get("arguments"):get("document") }) },
      { "ordered", true },
    })
    assert(runner:match(expected_command, actual_command))

    assert.are.equal(5, executed + 1)
  end)

  it("matches the pinned GridFS hexadecimal byte expectation", function()
    local fixture = meta_fixture("valid-pass", "poc-gridfs")
    local operation = fixture:get("tests"):get(2):get("operations"):get(1)
    local runner = assert(unified.new({ runtime = fake_runtime.new() }))

    assert(runner:match(
      operation:get("expectResult"),
      string.char(0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa)
    ))
  end)

  it("matches pinned entity, optional, and session expectations", function()
    local runner = assert(unified.new({ runtime = fake_runtime.new() }))
    local object_id = bson.object_id("000000000000000000000005")
    assert(runner:add_entity("oid0", "bson", object_id))

    local gridfs = meta_fixture("valid-pass", "poc-gridfs")
    local gridfs_expected = gridfs:get("tests"):get(5):get("operations")
      :get(2):get("expectResult"):get(1)
    assert(runner:match(gridfs_expected:get("_id"), object_id))
    assert(runner:match(gridfs_expected:get("md5"), nil))
    assert(runner:match(
      gridfs_expected:get("md5"),
      "283d4fea5dded59cf837d3047328f5af"
    ))

    local lsid = bson.document({
      { "id", bson.binary("session-id") },
      { "uid", bson.binary("user-id") },
    })
    assert(runner:add_entity("session0", "session", { lsid = lsid }))
    local sessions = meta_fixture("valid-pass", "poc-sessions")
    local lsid_expected = sessions:get("tests"):get(1):get("expectEvents")
      :get(1):get("events"):get(1):get("commandStartedEvent")
      :get("command"):get("lsid")
    assert(runner:match(lsid_expected, bson.document({
      { "uid", bson.binary("user-id") },
      { "id", bson.binary("session-id") },
    })))
  end)

  it("keeps iterable roots permissive and outcome documents exact", function()
    local expected = bson.array({ bson.document({ { "x", bson.int32(1) } }) })
    local extra = bson.array({ bson.document({
      { "y", bson.int32(2) },
      { "x", bson.int64(1) },
    }) })
    local runner = assert(unified.new({
      runtime = fake_runtime.new(),
      outcome_reader = function()
        return extra
      end,
    }))

    assert(runner:match(expected, extra))
    local ok = runner:verify_outcomes(bson.array({
      bson.document({ { "documents", expected } }),
    }))
    assert.is_nil(ok)

    local reordered = bson.array({ bson.document({
      { "y", bson.int32(2) },
      { "x", bson.int32(1) },
    }) })
    runner = assert(unified.new({
      runtime = fake_runtime.new(),
      outcome_reader = function()
        return reordered
      end,
    }))
    assert(runner:verify_outcomes(bson.array({
      bson.document({ { "documents", bson.array({ bson.document({
        { "x", bson.int64(1) },
        { "y", bson.int32(2) },
      }) }) } }),
    })))
  end)
end)
