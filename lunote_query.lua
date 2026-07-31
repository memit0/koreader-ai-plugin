local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local socketutil = require("socketutil")

local Env = require("lunote_env")
local Sync = require("lunote_sync")

-- IN A LATER VERSION, THIS WILL BE REMOVED
local api_key_module = Env.loadOptional("api_key")
local api_key = api_key_module and api_key_module.key

local CONFIGURATION = Env.loadOptional("lunote_config")

-- The request blocks the UI, so cap how long we are willing to wait.
local BLOCK_TIMEOUT = 30
local TOTAL_TIMEOUT = 120

-- OpenRouter speaks the OpenAI chat-completions dialect, so base_url can be
-- overridden in lunote_config.lua to point at anything else that does too
-- (a local Ollama, or any other OpenAI-compatible endpoint).
local PROVIDER = {
  env_key = "OPENROUTER_API_KEY",
  env_model = "OPENROUTER_MODEL",
  base_url = "https://openrouter.ai/api/v1/chat/completions",
  -- Cheap, fast and more than good enough to explain a paragraph of prose.
  model = "google/gemini-2.5-flash-lite",
}

local PLACEHOLDER_KEYS = {
  ["YOUR_API_KEY"] = true,
  ["YOUR_OPENROUTER_API_KEY"] = true,
}

local function configuredKey()
  local key = CONFIGURATION and CONFIGURATION.api_key
  if not key or key == "" or PLACEHOLDER_KEYS[key] then return nil end
  return key
end

-- Precedence is the same for every setting: lunote_config.lua, then .env,
-- then the default.
--
-- Above all of it sits managed mode, but only when nothing local is configured.
-- A key the reader put there themselves always wins: somebody who has both a
-- subscription and their own key keeps paying their own provider, and a working
-- free setup can never silently start spending someone else's money.
local function resolveSettings()
  local api_key_value = configuredKey() or Env.get(PROVIDER.env_key) or api_key
  local api_url = (CONFIGURATION and CONFIGURATION.base_url) or PROVIDER.base_url

  if not api_key_value and not (CONFIGURATION and CONFIGURATION.base_url) then
    local managed_url = Sync.getManagedUrl()
    if managed_url then
      -- The token from pairing is the credential; the web app picks the model,
      -- so we deliberately send none.
      return PROVIDER, Sync.getToken(), managed_url, nil
    end
  end

  local model = (CONFIGURATION and CONFIGURATION.model)
    or Env.get(PROVIDER.env_model)
    or Env.get("AI_MODEL")
    or PROVIDER.model
  return PROVIDER, api_key_value, api_url, model
end

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
local function queryModel(message_history)
  local provider, api_key_value, api_url, model = resolveSettings()

  if not api_key_value then
    return nil, string.format(
      "No API key found. Either pair this device with the web app "
        .. "(Menu > Lunote > Pair with web app) and subscribe there, or put "
        .. "%s=... in a .env file in the lunote.koplugin directory.",
      provider.env_key)
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

  -- Optional attribution headers, used by OpenRouter for its app rankings
  if api_url:find("openrouter.ai", 1, true) then
    headers["HTTP-Referer"] = "https://github.com/memit0/koreader-ai-plugin"
    headers["X-Title"] = "Lunote for KOReader"
  end

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

  -- The model is returned as well so callers can record which one answered
  return choice.message.content, nil, response.model or model
end

return queryModel
