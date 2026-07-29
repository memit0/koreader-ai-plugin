local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local socketutil = require("socketutil")

local api_key = nil
local CONFIGURATION = nil

-- Attempt to load the api_key module. IN A LATER VERSION, THIS WILL BE REMOVED
local success, result = pcall(function() return require("api_key") end)
if success then
  api_key = result.key
else
  print("api_key.lua not found, skipping...")
end

-- Attempt to load the configuration module
success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

-- The request blocks the UI, so cap how long we are willing to wait.
local BLOCK_TIMEOUT = 30
local TOTAL_TIMEOUT = 120

-- Turn whatever the API sent back into something worth showing the user.
local function describeApiError(code, body)
  local ok, decoded = pcall(json.decode, body)
  if ok and type(decoded) == "table" and type(decoded.error) == "table" and decoded.error.message then
    return decoded.error.message
  end
  if body and body ~= "" then
    return string.format("HTTP %s: %s", tostring(code), body:sub(1, 300))
  end
  return "HTTP " .. tostring(code)
end

-- Returns the assistant's reply, or nil plus an error message.
-- It never raises: an uncaught error here takes the whole reader down with it.
local function queryChatGPT(message_history)
  -- Use api_key from CONFIGURATION or fallback to the api_key module
  local api_key_value = CONFIGURATION and CONFIGURATION.api_key or api_key
  local api_url = CONFIGURATION and CONFIGURATION.base_url or "https://api.openai.com/v1/chat/completions"
  local model = CONFIGURATION and CONFIGURATION.model or "gpt-4o-mini"

  if not api_key_value or api_key_value == "" then
    return nil, "No API key found. Create a configuration.lua file in the askgpt.koplugin directory (see configuration.lua.sample)."
  end

  -- Determine whether to use http or https
  local request_library = api_url:match("^https://") and https or http

  -- Start building the request body
  local requestBodyTable = {
    model = model,
    messages = message_history,
  }

  -- Add additional parameters if they exist
  if CONFIGURATION and CONFIGURATION.additional_parameters then
    for key, value in pairs(CONFIGURATION.additional_parameters) do
      requestBodyTable[key] = value
    end
  end

  -- Encode the request body as JSON
  local encoded, requestBody = pcall(json.encode, requestBodyTable)
  if not encoded then
    return nil, "Could not encode the request: " .. tostring(requestBody)
  end

  local headers = {
    ["Content-Type"] = "application/json",
    ["Content-Length"] = tostring(#requestBody),
    ["Authorization"] = "Bearer " .. api_key_value,
  }

  local responseBody = {}

  -- Make the HTTP/HTTPS request
  socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
  local ok, res, code = pcall(request_library.request, {
    url = api_url,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(requestBody),
    sink = socketutil.table_sink(responseBody),
  })
  socketutil:reset_timeout()

  if not ok then
    return nil, "Could not reach " .. api_url .. ": " .. tostring(res)
  end
  if not res then
    -- LuaSocket/LuaSec signal transport failures as nil plus a message
    return nil, "Could not reach " .. api_url .. ": " .. tostring(code)
  end

  local body = table.concat(responseBody)
  if code ~= 200 then
    return nil, describeApiError(code, body)
  end

  local decoded, response = pcall(json.decode, body)
  if not decoded or type(response) ~= "table" then
    return nil, "Could not understand the API response."
  end
  if type(response.error) == "table" and response.error.message then
    return nil, response.error.message
  end

  local choice = response.choices and response.choices[1]
  if not (choice and choice.message and choice.message.content) then
    return nil, "The API did not return an answer."
  end

  return choice.message.content
end

return queryChatGPT
