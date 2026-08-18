local cursor_model = require("mongodb.cursor")
local errors = require("mongodb.error")

local M = {}

local STREAM_STATES = setmetatable({}, { __mode = "k" })
local STREAM_METHODS = {}

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

local function advance(value, cooperative)
  local state = STREAM_STATES[value]
  local document, err

  if cooperative then
    document, err = cursor_model.try_next(state.cursor)
  else
    document, err = state.cursor:next()
  end

  if not document then
    if err then
      return nil, err
    end

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

  local value = {}
  local post_batch_resume_token, has_next = cursor_model.resume_info(cursor)
  local resume_token = options.resume_token

  if not has_next and post_batch_resume_token ~= nil then
    resume_token = post_batch_resume_token
  end

  STREAM_STATES[value] = {
    cursor = cursor,
    resume_token = resume_token,
  }
  return setmetatable(value, STREAM_METATABLE)
end

return M
