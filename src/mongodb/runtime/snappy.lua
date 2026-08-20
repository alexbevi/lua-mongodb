local errors = require("mongodb.error")

local M = {}

local COMPRESSOR_ID = 1

local function require_string(name, value)
  if type(value) ~= "string" then
    error(name .. " must be a string", 3)
  end
end

local function operation_error(operation, category)
  return errors.new({
    category = category,
    message = "Snappy " .. operation .. " failed",
  })
end

local function transform(binding, method, operation, data, category)
  require_string("Snappy " .. operation .. " input", data)

  local outcome = table.pack(pcall(binding[method], data))

  if not outcome[1] or type(outcome[2]) ~= "string" then
    return nil, operation_error(operation, category)
  end

  return outcome[2]
end

function M.new(binding)
  if type(binding) ~= "table"
      or type(binding.compress) ~= "function"
      or type(binding.decompress) ~= "function" then
    error("Snappy binding must provide compress and decompress functions", 2)
  end

  return {
    compressor_id = COMPRESSOR_ID,
    compress = function(_, data)
      return transform(
        binding,
        "compress",
        "compression",
        data,
        errors.CATEGORY.INTERNAL
      )
    end,
    decompress = function(_, data)
      return transform(
        binding,
        "decompress",
        "decompression",
        data,
        errors.CATEGORY.PROTOCOL
      )
    end,
    name = "snappy",
  }
end

function M.load(loader)
  loader = loader or require

  if type(loader) ~= "function" then
    error("Snappy loader must be a function", 2)
  end

  local outcome = table.pack(pcall(loader, "snappy"))

  if not outcome[1] or type(outcome[2]) ~= "table" then
    return nil
  end

  local built = table.pack(pcall(M.new, outcome[2]))

  if not built[1] then
    return nil
  end

  return built[2]
end

return M
