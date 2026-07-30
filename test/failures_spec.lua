-- The original crash-path coverage, carried over to the store/sync architecture.
-- KOReader runs scheduled tasks unprotected, so any raise here kills the reader.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local ko = dofile(here .. "/support.lua")
local check = ko.check

local function makeUI()
    local ui
    ui = {
        annotation = { annotations = {} },
        document = { file = "/b.epub",
                     getProps = function() return { title = "B", authors = "A" } end },
        menu = { registerToMainMenu = function() end },
        handleEvent = function() end,
        highlight = {
            _highlight_buttons = {},
            selected_text = { text = "a passage" },
            addToHighlightDialog = function(self, idx, fn) self._highlight_buttons[idx] = fn end,
            onClose = function() end,
            saveHighlight = function()
                table.insert(ui.annotation.annotations,
                    { datetime = "2026-07-29 10:00:00", text = "a passage" })
                return #ui.annotation.annotations
            end,
        },
    }
    return ui
end

print("API failure modes (must never raise)")

local cases = {
    { name = "happy path", status = 200,
      response = { choices = { { message = { content = "an explanation" } } } } },
    { name = "401 bad key", status = 401,
      response = { error = { message = "Incorrect API key provided." } } },
    { name = "429 rate limit", status = 429, response = { error = { message = "Rate limited." } } },
    { name = "500 server error", status = 500, response = {} },
    { name = "no choices in body", status = 200, response = { id = "x" } },
    { name = "empty response", status = 200, response = {} },
    { name = "network down", status = 200, response = {}, transport = true },
    { name = "socket raises", status = 200, response = {}, raise = true },
}

for _, case in ipairs(cases) do
    ko.reset()
    local History = require("lunote_history")
    local ui = makeUI()
    local plugin = dofile(ko.PLUGIN .. "/main.lua")
    plugin:new{ ui = ui, view = {}, document = ui.document }

    ko.http.status, ko.http.response = case.status, case.response
    if case.transport then ko.http.fail_after = 0 end
    if case.raise then
        ko.modules["socket.http"].request = function() error("boom") end
        ko.modules["ssl.https"].request = function() error("boom") end
    end

    local ok, err = pcall(function()
        ui.highlight._highlight_buttons["lunote_01_explain"](ui.highlight, nil).callback()
        ko.drain()
    end)
    check(case.name, ok, err)

    if case.raise then
        -- restore for the next case
        local function fake(reqt)
            if reqt.sink then reqt.sink("RESPONSE") end
            return 1, ko.http.status, {}, ""
        end
        ko.modules["socket.http"].request = fake
        ko.modules["ssl.https"].request = fake
    end
end

print("\nstore failures degrade instead of raising")
ko.reset()
local History = require("lunote_history")
-- Point the store at a path that cannot be created
local Broken = setmetatable({}, { __index = History })
ko.modules["datastorage"].getSettingsDir = function() return "/nonexistent/nope" end
package.loaded["lunote_history"] = nil
local BrokenHistory = require("lunote_history")
local ok, err = pcall(function()
    return BrokenHistory.startConversation{
        book = { title = "t", authors = "a", md5 = "m" },
        messages = { { role = "user", content = "q" } },
    }
end)
check("unwritable database returns nil rather than raising", ok, err)
check("countDirty tolerates a broken database", pcall(BrokenHistory.countDirty))
ko.modules["datastorage"].getSettingsDir = function() return ko.SCRATCH .. "/dbdir" end

ko.summary()
