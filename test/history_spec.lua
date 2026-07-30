local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local ko = dofile(here .. "/support.lua")
local check = ko.check

print("history.lua")
ko.reset()
local History = require("history")

local BOOK = { title = "Critique of Pure Reason", authors = "Kant", md5 = "abc", file = "/k.epub" }

-- schema + identity
local device_uuid = History.getState("device_uuid")
check("device uuid generated", device_uuid and #device_uuid == 16, device_uuid)
check("device uuid is stable", History.getState("device_uuid") == device_uuid)

-- conversations
local id = History.startConversation{
    book = BOOK, kind = "explain", highlight = "the categorical imperative",
    chapter = "Ch 1", pageno = 42, annotation_datetime = "2026-07-29 10:00:00",
    model = "google/gemini-2.5-flash-lite",
    messages = {
        { role = "user", content = "the categorical imperative" },
        { role = "assistant", content = "Kant argues duty comes first." },
    },
}
check("conversation created", id == 1, id)

local books = History.listBooks()
check("one book listed", #books == 1 and books[1].title == "Critique of Pure Reason")
check("book counts conversations", tonumber(books[1].n_conversations) == 1)

local messages = History.getMessages(id)
check("two messages stored", #messages == 2, #messages)
check("message order preserved", messages[1].role == "user" and messages[2].role == "assistant")

-- a second conversation in the same book must not create a second book row
History.startConversation{ book = BOOK, kind = "explain", highlight = "second",
    messages = { { role = "user", content = "second" }, { role = "assistant", content = "ok" } } }
check("book deduplicated on (title, authors, md5)", #History.listBooks() == 1)
check("two conversations listed", #History.listConversations(1) == 2)

-- follow-up questions extend the same conversation and re-dirty it
History.markSynced("conversation", { id })
History.appendMessages(id, {
    { role = "user", content = "why?" },
    { role = "assistant", content = "because reason." },
})
check("follow-up appended", #History.getMessages(id) == 4)
local dirty = History.getDirtyConversations(0, 25)
local found = false
for _, record in ipairs(dirty.records) do
    if record.highlight == "the categorical imperative" then found = true end
end
check("follow-up re-marks conversation dirty", found)

-- annotation mirroring
print("\nannotation mirroring")
local MARKER = History.AI_NOTE_MARKER
local SEPARATOR = History.AI_NOTE_SEPARATOR
-- Two shapes reach the store: appended after a note the reader wrote, and
-- standing alone on a highlight that had none. Both must strip, or the
-- explanation syncs as if the reader had written it.
check("strips when appended to a note",
    History.stripAiNote("my note" .. SEPARATOR .. "AI text") == "my note",
    History.stripAiNote("my note" .. SEPARATOR .. "AI text"))
check("nil when the note is only an explanation",
    History.stripAiNote(MARKER .. "\nAI text") == nil,
    tostring(History.stripAiNote(MARKER .. "\nAI text")))
check("untouched without marker", History.stripAiNote("just mine") == "just mine")
check("trailing whitespace trimmed off the user part",
    History.stripAiNote("mine\n\n" .. MARKER .. "\nAI") == "mine")

ko.reset()
History = require("history")

local annotations = {
    { datetime = "2026-07-29 10:00:00", text = "passage one", note = "my thought",
      chapter = "Ch 1", pageno = 10 },
    { datetime = "2026-07-29 11:00:00", text = "passage two",
      note = "mine" .. SEPARATOR .. "the explanation", chapter = "Ch 2", pageno = 20 },
    { datetime = "2026-07-29 11:30:00", text = "passage three",
      note = MARKER .. "\nexplanation only", chapter = "Ch 3", pageno = 30 },
    { datetime = "2026-07-29 12:00:00", text = "", note = nil }, -- page bookmark: skipped
}
local changed = History.mirrorAnnotations(BOOK, annotations)
check("mirrored three of four", changed == 3, changed)

local items = History.getDirtyItems(0, 25)
check("three items dirty", #items.records == 3, #items.records)
local by_text = {}
for _, record in ipairs(items.records) do by_text[record.text] = record end
check("user note kept", by_text["passage one"].note == "my thought")
check("AI text stripped from mirrored note", by_text["passage two"].note == "mine",
    by_text["passage two"].note)
check("explanation-only note mirrors as no note",
    by_text["passage three"].note == nil or by_text["passage three"].note == "",
    tostring(by_text["passage three"].note))

-- re-mirroring unchanged annotations must not re-dirty them
History.markSynced("item", items.ids)
check("nothing dirty after sync", (History.countDirty() or -1) == 0, History.countDirty())
local again = History.mirrorAnnotations(BOOK, annotations)
check("unchanged annotations are not re-sent", again == 0, again)

-- an edited note is picked up
annotations[1].note = "my thought, revised"
check("edited annotation re-dirties", History.mirrorAnnotations(BOOK, annotations) == 1)
check("only the edited one is dirty", #History.getDirtyItems(0, 25).records == 1)

History.markSynced("item", History.getDirtyItems(0, 25).ids)
annotations[1].note = "my thought, rewrite"
check("same-length edit re-dirties", History.mirrorAnnotations(BOOK, annotations) == 1)
History.markSynced("item", History.getDirtyItems(0, 25).ids)
annotations[1].chapter = "A new chapter"
check("chapter edit re-dirties", History.mirrorAnnotations(BOOK, annotations) == 1)

-- batching and keyset pagination
print("\nbatching")
ko.reset()
History = require("history")
for i = 1, 12 do
    History.startConversation{ book = BOOK, kind = "explain", highlight = "h" .. i,
        messages = { { role = "user", content = "q" }, { role = "assistant", content = "a" } } }
end
local first = History.getDirtyConversations(0, 5)
check("first page bounded by limit", #first.records == 5, #first.records)
local second = History.getDirtyConversations(first.cursor, 5)
check("second page continues from cursor", #second.records == 5)
check("pages do not overlap", first.records[1].uuid ~= second.records[1].uuid)
local third = History.getDirtyConversations(second.cursor, 5)
check("final page is short", #third.records == 2, #third.records)
check("uuids are globally unique", first.records[1].uuid:match("^%x+:conversation:%d+$") ~= nil,
    first.records[1].uuid)
check("batch carries its book", #first.books == 1 and first.books[1].title == BOOK.title)
check("messages included in batch", #first.records[1].messages == 2)

-- pruning
History.markSynced("conversation", first.ids)
History.prune(os.time() + 10)
check("prune drops synced rows only", #History.listConversations(1) == 7,
    #History.listConversations(1))

ko.summary()
