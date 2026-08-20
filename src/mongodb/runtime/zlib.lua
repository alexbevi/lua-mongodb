local errors = require("mongodb.error")

local M = {}

local COMPRESSOR_ID = 2

local function require_string(name, value, level)
  if type(value) ~= "string" then
    error(name .. " must be a string", level or 3)
  end
end

local function require_level(level)
  if math.type(level) ~= "integer" or level < -1 or level > 9 then
    error("zlib compression level must be an integer from -1 through 9", 3)
  end
end

local function operation_error(operation, category)
  return errors.new({
    category = category,
    message = "zlib " .. operation .. " failed",
  })
end

local function new_stream(factory, argument)
  local outcome

  if argument == nil then
    outcome = table.pack(pcall(factory))
  else
    outcome = table.pack(pcall(factory, argument))
  end

  if not outcome[1] or type(outcome[2]) ~= "function" then
    return nil
  end

  return outcome[2]
end

local function compress(binding, data, level)
  require_string("zlib compression input", data)
  require_level(level)

  local stream = new_stream(binding.deflate, level)

  if stream == nil then
    return nil, operation_error("compression", errors.CATEGORY.INTERNAL)
  end

  local outcome = table.pack(pcall(stream, data, "finish"))

  if not outcome[1]
      or type(outcome[2]) ~= "string"
      or outcome[3] ~= true
      or outcome[4] ~= #data then
    return nil, operation_error("compression", errors.CATEGORY.INTERNAL)
  end

  return outcome[2]
end

local function decompress(binding, data)
  require_string("zlib decompression input", data)

  local stream = new_stream(binding.inflate)

  if stream == nil then
    return nil, operation_error("decompression", errors.CATEGORY.INTERNAL)
  end

  local outcome = table.pack(pcall(stream, data))

  if not outcome[1]
      or type(outcome[2]) ~= "string"
      or outcome[3] ~= true
      or outcome[4] ~= #data then
    return nil, operation_error("decompression", errors.CATEGORY.PROTOCOL)
  end

  return outcome[2]
end

function M.new(binding)
  if type(binding) ~= "table"
      or type(binding.deflate) ~= "function"
      or type(binding.inflate) ~= "function" then
    error("zlib binding must provide deflate and inflate functions", 2)
  end

  return {
    compressor_id = COMPRESSOR_ID,
    compress = function(_, data, level)
      return compress(binding, data, level)
    end,
    decompress = function(_, data)
      return decompress(binding, data)
    end,
    name = "zlib",
  }
end

function M.load(loader)
  loader = loader or require

  if type(loader) ~= "function" then
    error("zlib loader must be a function", 2)
  end

  local outcome = table.pack(pcall(loader, "zlib"))

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
