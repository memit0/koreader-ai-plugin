local https = require("ssl.https")
local json = require("json")
local socketutil = require("socketutil")
local meta = require("_meta")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local RELEASES_URL = "https://api.github.com/repos/memit0/koreader-ai-plugin/releases/latest"

local function parseVersion(tag)
  if type(tag) ~= "string" then return nil end
  local version = tag:match("^v?(%d+%.?%d*%.?%d*)$")
  if not version then return nil end
  local parts = {}
  for part in version:gmatch("%d+") do parts[#parts + 1] = tonumber(part) end
  return parts
end

local function isNewer(latest, current)
  latest, current = parseVersion(latest), parseVersion(current)
  if not latest or not current then return false end
  for i = 1, math.max(#latest, #current) do
    local a, b = latest[i] or 0, current[i] or 0
    if a ~= b then return a > b end
  end
  return false
end

local function checkForUpdates()
  local response_body = {}
  -- The URL is https, so this has to go through ssl.https: socket.http cannot
  -- speak TLS and would never get a response.
  socketutil:set_timeout(5, 10)
  local ok, res, code = pcall(https.request, {
    url = RELEASES_URL,
    headers = {
      ["Accept"] = "application/vnd.github.v3+json",
      -- GitHub rejects API requests without a User-Agent
      ["User-Agent"] = "askgpt.koplugin",
    },
    sink = socketutil.table_sink(response_body),
  })
  socketutil:reset_timeout()

  if not ok or not res or code ~= 200 then
    print("Failed to check for updates. HTTP code:", tostring(ok and code or res))
    return
  end

  local decoded, parsed_data = pcall(json.decode, table.concat(response_body))
  if not decoded or type(parsed_data) ~= "table" then
    print("Failed to check for updates: could not parse the release data.")
    return
  end

  -- Show notification to the user if a new version is available
  if isNewer(parsed_data.tag_name, tostring(meta.version)) then
    local message = "A new version of the app (" .. parsed_data.tag_name .. ") is available. Please update!"
    UIManager:show(InfoMessage:new{
      text = message,
      timeout = 5 -- Display message for 5 seconds
    })
  end
end

return {
  checkForUpdates = checkForUpdates,
  isNewer = isNewer,
}
