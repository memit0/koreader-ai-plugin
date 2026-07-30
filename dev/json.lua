--[[--
A small JSON codec, so the simulator needs no compiled modules.

KOReader ships its own `json`, and the plugin uses that; this exists only to
stand in for it on a desktop, where getting lua-cjson built against LuaJIT is
more trouble than the dependency is worth.

Deliberately not a general-purpose library: it handles what the plugin actually
sends and receives. Empty tables encode as `{}`, since nothing in the payloads is
ever an empty array.
]]
local Json = {}

-- Encoding -------------------------------------------------------------------

local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escapeString(value)
    return '"' .. value:gsub('[%c"\\]', function(character)
        return ESCAPES[character] or string.format("\\u%04x", character:byte())
    end) .. '"'
end

local function isArray(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" then return false end
        count = count + 1
    end
    return count == #value
end

local encodeValue

local function encodeTable(value)
    if isArray(value) and #value > 0 then
        local parts = {}
        for index = 1, #value do
            parts[index] = encodeValue(value[index])
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local parts = {}
    for key, entry in pairs(value) do
        if type(key) == "string" or type(key) == "number" then
            parts[#parts + 1] = escapeString(tostring(key)) .. ":" .. encodeValue(entry)
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encodeValue = function(value)
    local kind = type(value)
    if value == nil then return "null" end
    if kind == "boolean" then return tostring(value) end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("cannot encode " .. tostring(value) .. " as JSON", 0)
        end
        -- Integers must not come out as "42.0"
        if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
            return string.format("%d", value)
        end
        return string.format("%.14g", value)
    end
    if kind == "string" then return escapeString(value) end
    if kind == "table" then return encodeTable(value) end
    error("cannot encode a " .. kind .. " as JSON", 0)
end

function Json.encode(value)
    return encodeValue(value)
end

-- Decoding -------------------------------------------------------------------

local UNESCAPES = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
    f = "\f", n = "\n", r = "\r", t = "\t",
}

--- Encodes a code point as UTF-8, for \uXXXX escapes.
local function utf8Encode(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    end
    return string.char(
        0xE0 + math.floor(code / 0x1000),
        0x80 + math.floor(code / 0x40) % 0x40,
        0x80 + code % 0x40)
end

local function skipSpace(text, position)
    local _, stop = text:find("^[ \t\r\n]*", position)
    return stop + 1
end

local parseValue

local function parseString(text, position)
    position = position + 1 -- opening quote
    local parts = {}
    while true do
        local character = text:sub(position, position)
        if character == "" then error("unterminated string in JSON", 0) end
        if character == '"' then
            return table.concat(parts), position + 1
        end
        if character == "\\" then
            local escape = text:sub(position + 1, position + 1)
            if escape == "u" then
                local hex = text:sub(position + 2, position + 5)
                local code = tonumber(hex, 16)
                if not code then error("bad \\u escape in JSON", 0) end
                -- Surrogate pair
                if code >= 0xD800 and code <= 0xDBFF
                    and text:sub(position + 6, position + 7) == "\\u" then
                    local low = tonumber(text:sub(position + 8, position + 11), 16)
                    if low and low >= 0xDC00 and low <= 0xDFFF then
                        code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                        parts[#parts + 1] = utf8Encode(code)
                        position = position + 12
                    else
                        parts[#parts + 1] = utf8Encode(code)
                        position = position + 6
                    end
                else
                    parts[#parts + 1] = utf8Encode(code)
                    position = position + 6
                end
            else
                local replacement = UNESCAPES[escape]
                if not replacement then error("bad escape \\" .. escape .. " in JSON", 0) end
                parts[#parts + 1] = replacement
                position = position + 2
            end
        else
            -- Take a whole run of ordinary characters at once
            local _, stop = text:find('^[^"\\]+', position)
            parts[#parts + 1] = text:sub(position, stop)
            position = stop + 1
        end
    end
end

local function parseArray(text, position)
    position = skipSpace(text, position + 1)
    local out = {}
    if text:sub(position, position) == "]" then return out, position + 1 end
    while true do
        local value
        value, position = parseValue(text, position)
        out[#out + 1] = value
        position = skipSpace(text, position)
        local character = text:sub(position, position)
        if character == "]" then return out, position + 1 end
        if character ~= "," then error("expected , or ] in JSON array", 0) end
        position = skipSpace(text, position + 1)
    end
end

local function parseObject(text, position)
    position = skipSpace(text, position + 1)
    local out = {}
    if text:sub(position, position) == "}" then return out, position + 1 end
    while true do
        if text:sub(position, position) ~= '"' then
            error("expected a key in JSON object", 0)
        end
        local key
        key, position = parseString(text, position)
        position = skipSpace(text, position)
        if text:sub(position, position) ~= ":" then
            error("expected : in JSON object", 0)
        end
        position = skipSpace(text, position + 1)
        local value
        value, position = parseValue(text, position)
        out[key] = value
        position = skipSpace(text, position)
        local character = text:sub(position, position)
        if character == "}" then return out, position + 1 end
        if character ~= "," then error("expected , or } in JSON object", 0) end
        position = skipSpace(text, position + 1)
    end
end

parseValue = function(text, position)
    position = skipSpace(text, position)
    local character = text:sub(position, position)
    if character == "" then error("unexpected end of JSON", 0) end
    if character == '"' then return parseString(text, position) end
    if character == "{" then return parseObject(text, position) end
    if character == "[" then return parseArray(text, position) end
    if text:sub(position, position + 3) == "true" then return true, position + 4 end
    if text:sub(position, position + 4) == "false" then return false, position + 5 end
    -- null decodes to nil, so `if response.error then` behaves the way the
    -- plugin expects for an explicit "error": null. Arrays in these payloads
    -- never contain null, where dropping it would shorten the array.
    if text:sub(position, position + 3) == "null" then return nil, position + 4 end

    local number = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", position)
    if number and number ~= "" then
        local parsed = tonumber(number)
        if parsed then return parsed, position + #number end
    end
    error("unexpected character '" .. character .. "' in JSON", 0)
end

function Json.decode(text)
    if type(text) ~= "string" then error("JSON input must be a string", 0) end
    local value, position = parseValue(text, 1)
    position = skipSpace(text, position)
    if position <= #text then error("trailing content after JSON value", 0) end
    return value
end

return Json
