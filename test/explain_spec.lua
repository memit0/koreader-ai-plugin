local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\][^/\]*$") or "."
local ko = dofile(here .. "/support.lua")
local check = ko.check

-- Builds a reader-like ui: a highlight module that can save a highlight, and an
-- annotation list the plugin writes into.
local function makeUI(annotations)
    local ui
    ui = {
        annotation = { annotations = annotations or {} },
        document = {
            file = "/books/kant.epub",
            getProps = function() return { title = "Critique", authors = "Kant" } end,
        },
        menu = { registerToMainMenu = function() end },
        handleEvent = function(_, event) table.insert(ko.events, event) end,
        highlight = {
            _highlight_buttons = {},
            selected_text = { text = "the categorical imperative" },
            addToHighlightDialog = function(self, idx, fn) self._highlight_buttons[idx] = fn end,
            onClose = function() end,
            saveHighlight = function()
                table.insert(ui.annotation.annotations, {
                    datetime = "2026-07-29 10:00:00", text = "the categorical imperative",
                    chapter = "Ch 1", pageno = 42,
                })
                return #ui.annotation.annotations
            end,
        },
    }
    return ui
end

local function loadPlugin(ui)
    local plugin = dofile(ko.PLUGIN .. "/main.lua")
    local instance = plugin:new{ ui = ui, view = {}, document = ui.document }
    return plugin, instance
end

local function pressExplain(ui, index)
    local fn = ui.highlight._highlight_buttons["askgpt_01_explain"]
    fn(ui.highlight, index).callback()
    ko.drain()
end

local ANSWER = "Kant argues that duty precedes consequence."
local function answerOK()
    ko.http.response = { choices = { { message = { content = ANSWER } } }, model = "test-model" }
end

print("explain on a fresh selection")
ko.reset()
local History = require("history")
local ui = makeUI()
local _, instance = loadPlugin(ui)
answerOK()
pressExplain(ui, nil)

local annotation = ui.annotation.annotations[1]
check("a highlight was created", annotation ~= nil)
check("explanation written into the note", annotation and annotation.note
    and annotation.note:find(ANSWER, 1, true) ~= nil, annotation and annotation.note)
check("note marked as markdown", annotation and annotation.note_format == "md")
local modified = false
for _, event in ipairs(ko.events) do
    if event.name == "AnnotationsModified" then modified = true end
end
check("AnnotationsModified fired so KOReader persists it", modified)

local books = History.listBooks()
check("book recorded", #books == 1 and books[1].title == "Critique", books[1] and books[1].title)
local conversations = History.listConversations(books[1].id)
check("conversation recorded", #conversations == 1)
check("highlight stored", conversations[1].highlight == "the categorical imperative")
check("chapter carried from the annotation", conversations[1].chapter == "Ch 1")
local messages = History.getMessages(conversations[1].id)
check("answer stored", #messages == 2 and messages[2].content == ANSWER)

print("\nexplain on an existing highlight keeps the user's note")
ko.reset()
History = require("history")
local existing = { {
    datetime = "2026-07-01 09:00:00", text = "an earlier passage",
    note = "my own thought", chapter = "Ch 2", pageno = 7,
} }
ui = makeUI(existing)
loadPlugin(ui)
answerOK()
pressExplain(ui, 1)

check("no extra highlight created", #ui.annotation.annotations == 1, #ui.annotation.annotations)
local note = ui.annotation.annotations[1].note
check("user's note preserved", note:sub(1, #"my own thought") == "my own thought", note)
check("explanation appended after it", note:find(ANSWER, 1, true) ~= nil)
check("separated by the marker", note:find(History.AI_NOTE_MARKER, 1, true) ~= nil)
check("mirroring strips it back to the user's note",
    History.stripAiNote(note) == "my own thought", History.stripAiNote(note))

print("\nfollow-up questions extend the same conversation")
local books2 = History.listBooks()
local conversation = History.listConversations(books2[1].id)[1]
local viewer
for _, widget in ipairs(ko.shown) do
    if widget.onAskQuestion then viewer = widget end
end
check("viewer is showing", viewer ~= nil)
answerOK()
viewer:onAskQuestion("why does he think that?")
ko.drain()
check("two more messages recorded", #History.getMessages(conversation.id) == 4,
    #History.getMessages(conversation.id))
check("conversation re-marked dirty", (function()
    for _, record in ipairs(History.getDirtyConversations(0, 25).records) do
        if record.highlight == "the categorical imperative" then return true end
    end
end)())

print("\nsave_to_notes = false keeps notes untouched")
ko.reset()
ko.modules["configuration"].features = { save_to_notes = false }
History = require("history")
ui = makeUI()
loadPlugin(ui)
answerOK()
pressExplain(ui, nil)
check("no annotation written", #ui.annotation.annotations == 0, #ui.annotation.annotations)
check("still recorded in history", #History.listConversations(1) == 1)

print("\nAPI failure changes nothing")
ko.reset()
History = require("history")
ui = makeUI()
loadPlugin(ui)
ko.http.status = 401
ko.http.response = { error = { message = "Incorrect API key provided." } }
local ok = pcall(pressExplain, ui, nil)
check("no crash", ok)
check("no highlight created", #ui.annotation.annotations == 0)
check("nothing recorded", #(History.listBooks() or {}) == 0)

print("\nfile manager context")
ko.reset()
local fm_ui = { menu = { registerToMainMenu = function() end } } -- no highlight, no document
local registered_ok, err = pcall(function()
    local plugin = dofile(ko.PLUGIN .. "/main.lua")
    local instance = plugin:new{ ui = fm_ui }
    local items = {}
    instance:addToMainMenu(items)
    return items
end)
check("init survives without a highlight module", registered_ok, err)

local menu_items = {}
ko.reset()
local plugin = dofile(ko.PLUGIN .. "/main.lua")
local fm_instance = plugin:new{ ui = { menu = { registerToMainMenu = function() end } } }
fm_instance:addToMainMenu(menu_items)
check("menu entry added", menu_items.askgpt ~= nil)
check("has browse and sync entries", #menu_items.askgpt.sub_item_table == 3,
    menu_items.askgpt and #menu_items.askgpt.sub_item_table)

print("\nmirroring on document close")
ko.reset()
History = require("history")
ui = makeUI({
    { datetime = "2026-07-29 10:00:00", text = "passage", note = "mine", pageno = 3 },
})
local _, reader_instance = loadPlugin(ui)
reader_instance:onCloseDocument()
check("annotations mirrored to the store", #History.getDirtyItems(0, 25).records == 1)

ko.summary()
