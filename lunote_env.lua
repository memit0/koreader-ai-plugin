--[[--
Reads simple KEY=VALUE pairs out of a `.env` file sitting next to the plugin,
falling back to the process environment. KOReader ships no dotenv support, so
this is deliberately small: blank lines, `#` comments, an optional `export`
prefix, and single- or double-quoted values.

The file is read once, so a restart is needed to pick up edits.
]]
local Env = {}

-- The plugin directory is not known until after main.lua has been loaded, so
-- work it out from this file's own path instead.
local function pluginDir()
  local source = debug.getinfo(1, "S").source
  if type(source) ~= "string" or source:sub(1, 1) ~= "@" then return nil end
  -- KOReader always loads us through a path with a directory component, but
  -- fall back to the working directory if this was loaded by bare filename.
  return source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
end

local function unquote(value)
  local quoted = value:match('^"(.*)"$') or value:match("^'(.*)'$")
  if quoted then return quoted end
  -- Only unquoted values can carry a trailing inline comment
  return (value:gsub("%s+#.*$", ""))
end

local function parse(path)
  local values = {}
  local file = io.open(path, "r")
  if not file then return values end

  for line in file:lines() do
    if not line:match("^%s*#") then
      local key, value = line:match("^%s*export%s+([%w_%.]+)%s*=%s*(.-)%s*$")
      if not key then
        key, value = line:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
      end
      if key then
        values[key] = unquote(value)
      end
    end
  end

  file:close()
  return values
end

local cached

local function values()
  if not cached then
    local dir = pluginDir()
    cached = dir and parse(dir .. "/.env") or {}
  end
  return cached
end

--- Returns the value for `name`, or nil if it is unset or empty.
function Env.get(name)
  local value = values()[name]
  if value == nil or value == "" then
    value = os.getenv and os.getenv(name) or nil
  end
  if value == "" then return nil end
  return value
end

return Env
