local cursor_model = require("mongodb.cursor")
local errors = require("mongodb.error")

local M = {}

local STREAM_STATES = setmetatable({}, { __mode = "k" })
local STREAM_METHODS = {}

local RESUMABLE_CODES = {
  [6] = true,
  [7] = true,
  [63] = true,
  [89] = true,
  [91] = true,
  [133] = true,
  [150] = true,
  [189] = true,
  [234] = true,
  [262] = true,
  [9001] = true,
  [10107] = true,
  [11600] = true,
  [11602] = true,
  [13388] = true,
  [13435] = true,
  [13436] = true,
}

local function immutable()
  error("MongoDB change streams are immutable", 2)
end

local STREAM_METATABLE = {
  __index = function(_, key)
    return STREAM_METHODS[key]
  end,
  __metatable = "mongodb.change_stream",
  __newindex = immutable,
}

local function missing_resume_token()
  return nil, errors.new({
    category = errors.CATEGORY.CLIENT,
    message = "Cannot provide resume functionality when the resume token is missing",
  })
end

local function is_network_error(err)
  local current = err

  while errors.is(current) do
    if errors.is(current, errors.CATEGORY.NETWORK) then
      return true
    end

    current = current.cause
  end

  return false
end

local function is_resumable(state, err)
  if is_network_error(err) or err.code == 43 then
    return true
  end

  if not errors.is(err, errors.CATEGORY.SERVER) then
    return false
  end

  if state.max_wire_version >= 9 then
    return err:has_label("ResumableChangeStreamError")
  end

  return RESUMABLE_CODES[err.code] == true
end

local function read_cursor(state, cooperative)
  local document, err

  if cooperative then
    document, err = cursor_model.try_next(state.cursor)
  else
    document, err = state.cursor:next()
  end

  return document, err
end

local function recreate_cursor(state)
  state.cursor:close()

  local cursor, err = state.recreate(state.resume_token)

  if not cursor then
    return nil, err
  end

  state.cursor = cursor

  local post_batch_resume_token, has_next = cursor_model.resume_info(cursor)

  if not has_next and post_batch_resume_token ~= nil then
    state.resume_token = post_batch_resume_token
  end

  return true
end

local function advance(value, cooperative)
  local state = STREAM_STATES[value]
  local document, err = read_cursor(state, cooperative)

  if err and state.recreate and is_resumable(state, err) then
    local recreated
    recreated, err = recreate_cursor(state)

    if not recreated then
      return nil, err
    end

    document, err = read_cursor(state, cooperative)
  end

  if err then
    return nil, err
  end

  if not document then

    local post_batch_resume_token = cursor_model.resume_info(state.cursor)

    if post_batch_resume_token ~= nil then
      state.resume_token = post_batch_resume_token
    end

    return nil
  end

  local resume_token = document:get("_id")

  if resume_token == nil then
    state.cursor:close()
    return missing_resume_token()
  end

  local post_batch_resume_token, has_next = cursor_model.resume_info(state.cursor)

  if not has_next and post_batch_resume_token ~= nil then
    resume_token = post_batch_resume_token
  end

  state.resume_token = resume_token
  return document
end

function STREAM_METHODS:next()
  return advance(self, false)
end

function STREAM_METHODS:try_next()
  return advance(self, true)
end

function STREAM_METHODS:iter()
  return function()
    return self:next()
  end
end

function STREAM_METHODS:is_closed()
  return STREAM_STATES[self].cursor:is_closed()
end

function STREAM_METHODS:resume_token()
  return STREAM_STATES[self].resume_token
end

function STREAM_METHODS:close(options)
  return STREAM_STATES[self].cursor:close(options)
end

function M.new(cursor, options)
  if type(cursor) ~= "table"
      or type(cursor.next) ~= "function"
      or type(cursor.close) ~= "function"
      or type(cursor.is_closed) ~= "function"
  then
    error("change stream creation requires a cursor", 2)
  end

  options = options or {}

  if type(options) ~= "table" then
    error("change stream options must be a table", 2)
  end

  if options.max_wire_version ~= nil
      and (math.type(options.max_wire_version) ~= "integer"
        or options.max_wire_version < 0)
  then
    error("change stream max wire version must be a non-negative integer", 2)
  end

  if options.recreate ~= nil and type(options.recreate) ~= "function" then
    error("change stream recreation must be a function", 2)
  end

  local value = {}
  local post_batch_resume_token, has_next = cursor_model.resume_info(cursor)
  local resume_token = options.resume_token

  if not has_next and post_batch_resume_token ~= nil then
    resume_token = post_batch_resume_token
  end

  STREAM_STATES[value] = {
    cursor = cursor,
    max_wire_version = options.max_wire_version or 0,
    recreate = options.recreate,
    resume_token = resume_token,
  }
  return setmetatable(value, STREAM_METATABLE)
end

return M
