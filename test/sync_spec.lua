local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\][^/\]*$") or "."
local ko = dofile(here .. "/support.lua")
local check = ko.check

local BOOK = { title = "Book", authors = "Author", md5 = "abc", file = "/b.epub" }

local function seed(History, conversations, items)
    for i = 1, conversations do
        History.startConversation{ book = BOOK, kind = "explain", highlight = "h" .. i,
            messages = { { role = "user", content = "q" }, { role = "assistant", content = "a" } } }
    end
    local annotations = {}
    for i = 1, items do
        annotations[i] = { datetime = "2026-07-29 10:00:" .. string.format("%02d", i),
            text = "passage " .. i, note = "note " .. i, pageno = i }
    end
    if items > 0 then History.mirrorAnnotations(BOOK, annotations) end
end

print("pairing")
ko.reset()
local History = require("history")
local Sync = require("sync")

check("not configured before pairing", Sync.isConfigured() == false)
ko.http.response = { token = "device-token-xyz" }
local ok, err = Sync.pair("ABC123")
check("pairing succeeds", ok == true, err)
check("token stored", Sync.getToken() == "device-token-xyz")
check("configured after pairing", Sync.isConfigured() == true)
local pair_payload = ko.http.sent[1]
check("pair sends the code", pair_payload.code == "ABC123")
check("pair sends the device uuid", pair_payload.device_uuid == History.getState("device_uuid"))

ko.http.response = {}
local rejected, reject_err = Sync.pair("BAD")
check("missing token is reported, not raised", rejected == nil and reject_err ~= nil, reject_err)

print("\nfull sync")
ko.reset()
History = require("history")
Sync = require("sync")
seed(History, 12, 3)
History.setState("token", "t")
check("15 records outstanding", History.countDirty() == 15, History.countDirty())

ko.http.response = { accepted = 25 }
local sent, sync_err
Sync.run{ done = function(n, e) sent, sync_err = n, e end }
check("all records sent", sent == 15, sent)
check("no error", sync_err == nil, sync_err)
check("nothing left dirty", History.countDirty() == 0, History.countDirty())
check("last_sync_at recorded", History.getState("last_sync_at") ~= nil)

-- 3 items = 1 batch, 12 conversations = 1 batch of 25... both fit in one page each
check("batched into two requests", #ko.http.sent == 2, #ko.http.sent)
local items_payload, conversations_payload = ko.http.sent[1], ko.http.sent[2]
check("items pushed before conversations", items_payload.items ~= nil
    and conversations_payload.conversations ~= nil)
check("payload carries books", #items_payload.books == 1
    and items_payload.books[1].title == "Book")
check("conversation payload carries messages",
    #conversations_payload.conversations[1].messages == 2)

print("\nre-syncing is a no-op")
local before = #ko.http.sent
Sync.run{ done = function(n) sent = n end }
check("nothing re-sent when clean", sent == 0, sent)
check("no extra requests made", #ko.http.sent == before, #ko.http.sent)

print("\nbatch size bounds each request")
ko.reset()
History = require("history")
Sync = require("sync")
seed(History, 60, 0)
History.setState("token", "t")
ko.http.response = { accepted = 25 }
Sync.run{ done = function(n, e) sent, sync_err = n, e end }
check("all 60 sent", sent == 60, sent)
check("split into 3 requests of <=25", #ko.http.sent == 3, #ko.http.sent)
local sizes = {}
for index, payload in ipairs(ko.http.sent) do sizes[index] = #payload.conversations end
check("batch sizes are 25/25/10", sizes[1] == 25 and sizes[2] == 25 and sizes[3] == 10,
    table.concat(sizes, "/"))

print("\ninterrupted sync resumes without duplicates")
ko.reset()
History = require("history")
Sync = require("sync")
seed(History, 60, 0)
History.setState("token", "t")
ko.http.response = { accepted = 25 }
ko.http.fail_after = 2 -- third request dies, as if wifi dropped
Sync.run{ done = function(n, e) sent, sync_err = n, e end }
check("partial send reported", sent == 50, sent)
check("failure surfaced to the caller", sync_err ~= nil, sync_err)
check("acknowledged batches are clean", History.countDirty() == 10, History.countDirty())

-- reconnect and finish the job
ko.http.fail_after = nil
local before_calls = #ko.http.sent
Sync.run{ done = function(n, e) sent, sync_err = n, e end }
check("resume sends only the remainder", sent == 10, sent)
check("resume took one request", #ko.http.sent - before_calls == 1)
check("everything is clean now", History.countDirty() == 0, History.countDirty())

print("\nfailure handling")
ko.reset()
History = require("history")
Sync = require("sync")
seed(History, 5, 0)
check("sync without a token is refused, not raised", (function()
    local message
    Sync.run{ done = function(_, e) message = e end }
    return message ~= nil
end)())
check("records stay dirty when unpaired", History.countDirty() == 5)

History.setState("token", "t")
ko.http.status = 500
Sync.run{ done = function(n, e) sent, sync_err = n, e end }
check("server error reported", sync_err ~= nil, sync_err)
check("nothing marked synced on server error", History.countDirty() == 5, History.countDirty())

ko.summary()
