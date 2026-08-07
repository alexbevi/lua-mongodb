package.path = "src/?.lua;src/?/init.lua;" .. package.path

local stress = require("spec.quality.stress")

local DEFAULT_SEEDS = "spec/quality/stress-seeds.txt"
local DEFAULT_FAILURE_REPORT = "build/quality/stress-failures.txt"

local function usage(message)
  if message then
    io.stderr:write("stress gate: ", message, "\n")
  end

  io.stderr:write(
    "usage: lua spec/quality/run_stress.lua ",
    "[--seed N] [--iterations N] [--seeds FILE] ",
    "[--failure-report FILE]\n"
  )
  os.exit(2)
end

local function positive_integer(name, text)
  local value = tonumber(text)

  if math.type(value) ~= "integer" or value <= 0 then
    usage(name .. " must be a positive integer")
  end

  return value
end

local function parse_arguments(arguments)
  local options = {
    failure_report = DEFAULT_FAILURE_REPORT,
    iterations = 4,
    seeds_path = DEFAULT_SEEDS,
  }
  local index = 1

  while index <= #arguments do
    local name = arguments[index]
    local value = arguments[index + 1]

    if name == "--seed" then
      options.seed = positive_integer("seed", value)
    elseif name == "--iterations" then
      options.iterations = positive_integer("iterations", value)
    elseif name == "--seeds" then
      options.seeds_path = value
    elseif name == "--failure-report" then
      options.failure_report = value
    else
      usage("unknown argument " .. tostring(name))
    end

    if value == nil then
      usage(name .. " requires a value")
    end

    index = index + 2
  end

  return options
end

local function read_seeds(path)
  local file, open_err = io.open(path, "r")

  if not file then
    usage("cannot read seeds file " .. path .. ": " .. tostring(open_err))
  end

  local seeds = {}

  for line in file:lines() do
    if not line:match("^%s*#") and line:match("%S") then
      seeds[#seeds + 1] = positive_integer("seed", line:match("^%s*(.-)%s*$"))
    end
  end

  file:close()

  if #seeds == 0 then
    usage("seeds file must contain at least one seed")
  end

  return seeds
end

local function retain_failures(path, failures, iterations)
  if #failures == 0 then
    os.remove(path)
    return true
  end

  local file, open_err = io.open(path, "w")

  if not file then
    io.stderr:write(
      "stress gate: cannot retain failure report ", path, ": ",
      tostring(open_err), "\n"
    )
    return false
  end

  file:write("lua=", _VERSION, " iterations=", iterations, "\n")

  for _, failure in ipairs(failures) do
    file:write("seed=", failure.seed, " error=", failure.error, "\n")
  end

  file:close()
  return true
end

local options = parse_arguments(arg)
local environment_seed = os.getenv("MONGODB_STRESS_SEED")
local seeds

if options.seed then
  seeds = { options.seed }
elseif environment_seed and environment_seed ~= "" then
  seeds = { positive_integer("MONGODB_STRESS_SEED", environment_seed) }
else
  seeds = read_seeds(options.seeds_path)
end

local failures = {}

for _, seed in ipairs(seeds) do
  local ok, result = pcall(stress.run_seed, seed, options.iterations)

  if not ok then
    failures[#failures + 1] = { error = tostring(result), seed = seed }
    io.stderr:write(
      "stress failure: seed=", seed,
      " iterations=", options.iterations,
      " lua=", _VERSION,
      " error=", tostring(result), "\n"
    )
  end
end

local retained = retain_failures(options.failure_report, failures, options.iterations)

if #failures > 0 or not retained then
  os.exit(1)
end

io.stdout:write(
  "deterministic stress: ", #seeds,
  " seeds passed, 0 failed; iterations=", options.iterations,
  "\n"
)
