local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local operation_timeout = require("mongodb.operation_timeout")

local M = {}

local CURSOR_STATES = setmetatable({}, { __mode = "k" })
local CURSOR_METHODS = {}

local function immutable()
  error("MongoDB cursors are immutable", 2)
end

local CURSOR_METATABLE = {
  __index = function(value, key)
    local method = CURSOR_METHODS[key]

    if method then
      return method
    end

    local state = CURSOR_STATES[value]

    if state then
      return state[key]
    end
  end,
  __metatable = "mongodb.cursor",
  __newindex = immutable,
}

local function protocol_error(message)
  return nil, errors.new({
    category = errors.CATEGORY.PROTOCOL,
    message = message,
  })
end

local function client_error(message)
  return nil, errors.new({
    category = errors.CATEGORY.CLIENT,
    message = message,
  })
end

local function number_value(value)
  if type(value) == "number" then
    return value
  end

  if bson.is_exact(value) then
    return value:to_number()
  end
end

local function cursor_id(value)
  local numeric = number_value(value)

  if math.type(numeric) ~= "integer" then
    return protocol_error("cursor response contains an invalid cursor id")
  end

  return value, numeric
end

local function response_batch(response, name)
  local cursor = response:get("cursor")

  if not bson.is_document(cursor) then
    return protocol_error("cursor response is missing its cursor document")
  end

  local id, numeric_id = cursor_id(cursor:get("id"))

  if id == nil then
    return nil, numeric_id
  end

  local batch = cursor:get(name)

  if not bson.is_array(batch) then
    return protocol_error("cursor response is missing its " .. name .. " array")
  end

  local documents = {}

  for index, document in batch:iter() do
    if not bson.is_document(document) then
      return protocol_error("cursor batch contains a non-document")
    end

    documents[index] = document
  end

  local post_batch_resume_token = cursor:get("postBatchResumeToken")

  if post_batch_resume_token ~= nil
      and not bson.is_document(post_batch_resume_token)
  then
    return protocol_error(
      "cursor response contains an invalid postBatchResumeToken"
    )
  end

  return {
    documents = documents,
    id = id,
    numeric_id = numeric_id,
    post_batch_resume_token = post_batch_resume_token,
  }
end

local function release_session_context(state)
  if state.session_context
      and type(state.executor.release_session_context) == "function"
  then
    state.executor:release_session_context(state.session_context)
    state.session_context = nil
  end
end

local function mark_closed(value, state)
  if state.closed then
    return
  end

  state.closed = true
  state.id = bson.int64(0)
  state.numeric_id = 0
  state.documents = {}
  state.position = 1
  release_session_context(state)

  if state.on_close then
    state.on_close(value)
  end
end

local function client_is_closed(state)
  return state.client_state and state.client_state.closed == true
end

local function get_more(value, state)
  local entries = {
    { "getMore", state.id },
    { "collection", state.collection_name },
  }
  local batch_size = state.batch_size

  if state.limit > 0 then
    local remaining = state.limit - state.retrieved

    if batch_size == 0 or remaining < batch_size then
      batch_size = remaining
    end
  end

  if batch_size > 0 then
    entries[#entries + 1] = { "batchSize", batch_size }
  end

  if state.comment ~= nil then
    entries[#entries + 1] = { "comment", state.comment }
  end

  if state.max_await_time_ms ~= nil then
    entries[#entries + 1] = { "maxTimeMS", state.max_await_time_ms }
  end

  local response, err = operation_timeout.resume(
    state.timeout_context,
    state.timeout_mode == "iteration",
    function(timeout_options)
      return state.executor:command(
        state.database_name,
        bson.document(entries),
        {
          cancellation = state.cancellation,
          deadline = timeout_options.deadline or state.deadline,
          server_address = state.server_address,
          session = state.session,
          session_context = state.session_context,
        }
      )
    end
  )

  if not response then
    if not errors.is(err, errors.CATEGORY.TIMEOUT) then
      mark_closed(value, state)
    end

    return nil, err
  end

  local batch
  batch, err = response_batch(response, "nextBatch")

  if not batch then
    mark_closed(value, state)
    return nil, err
  end

  state.documents = batch.documents
  state.id = batch.id
  state.numeric_id = batch.numeric_id
  state.post_batch_resume_token = batch.post_batch_resume_token
  state.position = 1

  if state.numeric_id == 0 then
    release_session_context(state)
  end

  return true
end

local function advance_once(value, state)
  if state.closed then
    if client_is_closed(state) then
      local _, err = client_error("client is closed")

      return nil, err, true
    end

    return nil, nil, true
  end

  if state.limit > 0 and state.retrieved >= state.limit then
    local closed, err = value:close()

    if closed == nil then
      return nil, err, true
    end

    return nil, nil, true
  end

  local document = state.documents[state.position]

  if document then
    state.position = state.position + 1
    state.retrieved = state.retrieved + 1

    if state.position > #state.documents and state.numeric_id == 0 then
      mark_closed(value, state)
    end

    return document, nil, true
  end

  if state.numeric_id == 0 then
    mark_closed(value, state)
    return nil, nil, true
  end

  if client_is_closed(state) then
    mark_closed(value, state)

    local _, err = client_error("client is closed")

    return nil, err, true
  end

  local fetched, err = get_more(value, state)

  if not fetched then
    return nil, err, true
  end

  document = state.documents[state.position]

  if document then
    state.position = state.position + 1
    state.retrieved = state.retrieved + 1

    if state.position > #state.documents and state.numeric_id == 0 then
      mark_closed(value, state)
    end

    return document, nil, true
  end

  if state.numeric_id == 0 then
    mark_closed(value, state)
    return nil, nil, true
  end

  return nil, nil, false
end

function CURSOR_METHODS:next()
  local state = CURSOR_STATES[self]

  while true do
    local document, err, finished = advance_once(self, state)

    if finished then
      return document, err
    end
  end
end

function CURSOR_METHODS:iter()
  return function()
    return self:next()
  end
end

function CURSOR_METHODS:is_closed()
  return CURSOR_STATES[self].closed
end

function CURSOR_METHODS:close(options)
  local state = CURSOR_STATES[self]

  if state.closed then
    return false
  end

  options = options or {}

  if type(options) ~= "table" then
    error("cursor close options must be a table", 2)
  end

  if client_is_closed(state) or state.numeric_id == 0 then
    mark_closed(self, state)
    return true
  end

  local id = state.id
  local context = state.timeout_context
  local response, err

  if context then
    response, err = operation_timeout.run(
      context.runtime,
      context.timeout_ms,
      options,
      function(timeout_options)
        return state.executor:command(
          state.database_name,
          bson.document({
            { "killCursors", state.collection_name },
            { "cursors", bson.array({ id }) },
          }),
          {
            cancellation = options.cancellation,
            deadline = timeout_options.deadline,
            server_address = state.server_address,
            session = state.session,
            session_context = state.session_context,
          }
        )
      end
    )
  else
    response, err = state.executor:command(
      state.database_name,
      bson.document({
        { "killCursors", state.collection_name },
        { "cursors", bson.array({ id }) },
      }),
      {
        cancellation = options.cancellation,
        deadline = options.deadline,
        server_address = state.server_address,
        session = state.session,
        session_context = state.session_context,
      }
    )
  end

  mark_closed(self, state)

  if not response then
    return nil, err
  end

  return true
end

function M.try_next(value)
  local state = CURSOR_STATES[value]

  if not state then
    error("cooperative iteration requires a cursor", 2)
  end

  local document, err = advance_once(value, state)

  return document, err
end

function M.resume_info(value)
  local state = CURSOR_STATES[value]

  if not state then
    error("resume information requires a cursor", 2)
  end

  return state.post_batch_resume_token,
    state.position <= #state.documents,
    state.operation_time
end

function M.new(response, options)
  if not bson.is_document(response) then
    error("cursor creation requires a command response", 2)
  end

  if type(options) ~= "table" then
    error("cursor creation options must be a table", 2)
  end

  local batch, err = response_batch(response, "firstBatch")

  if not batch then
    if options.session_context
        and type(options.executor.release_session_context) == "function"
    then
      options.executor:release_session_context(options.session_context)
    end

    return nil, err
  end

  local value = {}

  CURSOR_STATES[value] = {
    batch_size = options.batch_size or 0,
    cancellation = options.cancellation,
    client_state = options.client_state,
    closed = false,
    collection_name = options.collection_name,
    comment = options.comment,
    database_name = options.database_name,
    deadline = options.deadline,
    documents = batch.documents,
    executor = options.executor,
    id = batch.id,
    limit = options.limit or 0,
    max_await_time_ms = options.max_await_time_ms,
    numeric_id = batch.numeric_id,
    on_close = options.on_close,
    operation_time = response:get("operationTime"),
    position = 1,
    post_batch_resume_token = batch.post_batch_resume_token,
    retrieved = 0,
    server_address = options.server_address,
    session = options.session,
    session_context = options.session_context,
    timeout_context = options.timeout_context,
    timeout_mode = options.timeout_mode or "cursor_lifetime",
  }
  local result = setmetatable(value, CURSOR_METATABLE)

  if batch.numeric_id == 0 then
    release_session_context(CURSOR_STATES[result])
  end

  if batch.numeric_id == 0 and #batch.documents == 0 then
    mark_closed(result, CURSOR_STATES[result])
  end

  return result
end

return M
