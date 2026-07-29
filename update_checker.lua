local https = require("ssl.https")
local json = require("json")
local socketutil = require("socketutil")
local meta = require("_meta")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local RELEASES_URL = "https://api.github.com/repos/drewbaumann/AskGPT/releases/latest"

-- Tags look like "v1.01"; pull the version number back out of them.
local function parseVersion(tag)
  if type(tag) ~= "string" then return nil end
  return tonumber(tag:match("(%d+%.?%d*)"))
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

  local latest_version = parseVersion(parsed_data.tag_name)
  local current_version = tonumber(meta.version)
  if not latest_version or not current_version then return end

  -- Show notification to the user if a new version is available
  if current_version < latest_version then
    local message = "A new version of the app (" .. parsed_data.tag_name .. ") is available. Please update!"
    UIManager:show(InfoMessage:new{
      text = message,
      timeout = 5 -- Display message for 5 seconds
    })
  end
end

return {
  checkForUpdates = checkForUpdates
}
