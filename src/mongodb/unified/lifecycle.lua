local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local runner_module = require("mongodb.unified.runner")

local M = {}

local LIFECYCLE_STATES = setmetatable({}, { __mode = "k" })

local function configuration_error(message, path)
  return errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    message = message,
    details = { path = path or "$" },
  })
end

local function document_has(document, wanted)
  if not bson.is_document(document) then
    return false
  end

  for key, value in document:iter() do
    if key == wanted then
      return true, value
    end
  end

  return false
end

local function require_success(value, err)
  if value == false or value == nil and err ~= nil then
    error(err or configuration_error("unified lifecycle phase failed"), 0)
  end

  return value
end

local function runner_options(state)
  local internal_client = state.internal_client
  local outcome_reader

  if internal_client and type(internal_client.read_outcome) == "function" then
    outcome_reader = function(_, specification)
      return internal_client:read_outcome(specification)
    end
  end

  return {
    entity_factories = state.entity_factories,
    entity_finalizers = state.entity_finalizers,
    environment = state.environment,
    operations = state.operations,
    outcome_reader = outcome_reader,
    runtime = state.runtime,
    session_lsid = state.session_lsid,
    test_operations = state.test_operations,
  }
end

local function new_runner(state)
  return runner_module.new(runner_options(state))
end

local function cleanup_runner(runner)
  local result = table.pack(pcall(runner.cleanup, runner))

  if not result[1] then
    return nil, result[2]
  end

  return result[2], result[3]
end

local function observe_entities(state, runner)
  if state.entity_observer then
    return state.entity_observer(runner)
  end

  return true
end

local function run_assertions(state, runner, test, path)
  local has_events, expected_events = document_has(test, "expectEvents")

  if has_events then
    if not state.assert_events then
      return nil, configuration_error("no event assertion adapter is configured", path)
    end

    local ok, err = state.assert_events(runner, expected_events)

    if ok == false or ok == nil and err ~= nil then
      return nil, err or configuration_error("event assertion failed", path)
    end
  end

  local has_outcome, outcome = document_has(test, "outcome")

  if has_outcome then
    return runner:verify_outcomes(outcome, path .. ".outcome")
  end

  return true
end

local function execute_test(state, document, test, index)
  local path = "$.tests[" .. index .. "]"
  local skip_reason = test:get("skipReason")

  if skip_reason then
    return { description = test:get("description"), reason = skip_reason, status = "skipped" }
  end

  local runner = new_runner(state)

  if not runner:should_run(test:get("runOnRequirements")) then
    cleanup_runner(runner)
    return {
      description = test:get("description"),
      reason = "test runOnRequirements not satisfied",
      status = "skipped",
    }
  end

  local main = table.pack(pcall(function()
    local initial_data = document:get("initialData")

    if initial_data then
      if not state.internal_client
        or type(state.internal_client.setup_initial_data) ~= "function" then
        error(configuration_error(
          "no internal client initial-data adapter is configured",
          "$.initialData"
        ), 0)
      end

      require_success(state.internal_client:setup_initial_data(initial_data))
    end

    local entities = document:get("createEntities")

    if entities then
      require_success(runner:create_entities(entities, "$.createEntities"))
    end

    require_success(runner:execute_all(test:get("operations"), path .. ".operations"))
  end))
  local ok = main[1]
  local failure = main[2]
  local finalized, finalize_err = runner:run_finalizers()

  if not finalized and ok then
    ok = false
    failure = finalize_err
  end

  if ok then
    local asserted = table.pack(pcall(run_assertions, state, runner, test, path))

    if not asserted[1] then
      ok = false
      failure = asserted[2]
    elseif asserted[2] == false or asserted[2] == nil and asserted[3] ~= nil then
      ok = false
      failure = asserted[3]
    end
  end

  local observed = table.pack(pcall(observe_entities, state, runner))

  if not observed[1] and ok then
    ok = false
    failure = observed[2]
  elseif observed[1] and (observed[2] == false
      or observed[2] == nil and observed[3] ~= nil) and ok then
    ok = false
    failure = observed[3]
  end

  local cleaned, cleanup_err = cleanup_runner(runner)

  if not cleaned and ok then
    ok = false
    failure = cleanup_err
  end

  local result = {
    description = test:get("description"),
    status = ok and "passed" or "failed",
  }

  if not ok then
    result.error = failure

    if cleanup_err and cleanup_err ~= failure then
      result.cleanup_error = cleanup_err
    end
  end

  return result
end

local LIFECYCLE_METHODS = {}
local LIFECYCLE_METATABLE = { __index = LIFECYCLE_METHODS }

function LIFECYCLE_METHODS:run_file(document, identity)
  if not bson.is_document(document) then
    return nil, configuration_error("unified test file must be an object", "$")
  end

  local tests = document:get("tests")

  if not bson.is_array(tests) then
    return nil, configuration_error("unified test file tests must be an array", "$.tests")
  end

  local state = LIFECYCLE_STATES[self]
  local evaluator = new_runner(state)
  local file_runs = evaluator:should_run(document:get("runOnRequirements"))

  cleanup_runner(evaluator)

  local report = {
    file = identity,
    summary = {
      executed = 0,
      failed = 0,
      passed = 0,
      selected = #tests,
      skipped = 0,
    },
    tests = {},
  }

  for index, test in tests:iter() do
    local result

    if not file_runs then
      result = {
        description = test:get("description"),
        reason = "file runOnRequirements not satisfied",
        status = "skipped",
      }
    else
      result = execute_test(state, document, test, index)
    end

    result.index = index
    report.tests[index] = result
    report.summary[result.status] = report.summary[result.status] + 1

    if result.status ~= "skipped" then
      report.summary.executed = report.summary.executed + 1
    end
  end

  return report
end

function LIFECYCLE_METHODS:close()
  local state = LIFECYCLE_STATES[self]

  if state.closed then
    return true
  end

  state.closed = true

  if state.internal_client and type(state.internal_client.close) == "function" then
    return state.internal_client:close()
  end

  return true
end


function M.new(options)
  options = options or {}

  if type(options) ~= "table" then
    error("unified lifecycle options must be a table", 2)
  end

  if options.internal_client ~= nil and type(options.internal_client) ~= "table" then
    error("unified lifecycle internal_client must be an adapter table", 2)
  end

  for _, name in ipairs({ "assert_events", "entity_observer", "session_lsid" }) do
    if options[name] ~= nil and type(options[name]) ~= "function" then
      error("unified lifecycle " .. name .. " must be a function", 2)
    end
  end

  local lifecycle = {}

  LIFECYCLE_STATES[lifecycle] = {
    assert_events = options.assert_events,
    closed = false,
    entity_factories = options.entity_factories or {},
    entity_finalizers = options.entity_finalizers or {},
    entity_observer = options.entity_observer,
    environment = options.environment or {},
    internal_client = options.internal_client,
    operations = options.operations or {},
    runtime = options.runtime,
    session_lsid = options.session_lsid,
    test_operations = options.test_operations or {},
  }

  return setmetatable(lifecycle, LIFECYCLE_METATABLE)
end

return M
