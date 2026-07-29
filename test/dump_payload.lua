-- Drives the real sync code and writes the exact payloads the device would put
-- on the wire to test/tmp/payloads.json, so the server can be checked against
-- them rather than against an assumption about them.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local ko = dofile(here .. "/support.lua")

local function encode(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "nil" then return "null" end
    if t == "number" then return tostring(value) end
    if t == "boolean" then return tostring(value) end
    if t == "string" then
        return '"' .. value:gsub('[%c"\\]', function(c)
            if c == '"' then return '\\"' end
            if c == "\\" then return "\\\\" end
            if c == "\n" then return "\\n" end
            return string.format("\\u%04x", c:byte())
        end) .. '"'
    end

    local is_array = #value > 0
    local inner = indent .. "  "
    local parts = {}
    if is_array then
        for _, entry in ipairs(value) do
            parts[#parts + 1] = inner .. encode(entry, inner)
        end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = inner .. '"' .. key .. '": ' .. encode(value[key], inner)
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

ko.reset()
local History = require("history")
local Sync = require("sync")

local BOOK = { title = "Critique of Pure Reason", authors = "Kant",
               md5 = "d41d8cd98f00b204", file = "/books/kant.epub" }

History.startConversation{
    book = BOOK, kind = "explain", highlight = "the categorical imperative",
    chapter = "Chapter 1", pageno = 42,
    annotation_datetime = "2026-07-29 10:00:00", model = "google/gemini-2.5-flash-lite",
    messages = {
        { role = "user", content = "the categorical imperative" },
        { role = "assistant", content = "Kant argues that duty precedes consequence." },
        { role = "user", content = "why does he think that?" },
        { role = "assistant", content = "Because reason alone can ground obligation." },
    },
}
History.mirrorAnnotations(BOOK, {
    { datetime = "2026-07-29 10:00:00", text = "the categorical imperative",
      note = "worth rereading", chapter = "Chapter 1", pageno = 42 },
})

History.setState("token", "device-token")
ko.http.response = { accepted = 1 }
Sync.run{ done = function() end }

local out = assert(io.open(here .. "/fixtures/payloads.json", "w"))
out:write(encode({ pair = { code = "ABC234", device_uuid = History.getState("device_uuid"),
                            device_name = "TestReader" },
                   sync = ko.http.sent }))
out:close()
print("wrote " .. #ko.http.sent .. " sync payload(s)")
