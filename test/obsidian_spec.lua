local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local ko = dofile(here .. "/support.lua")
local check = ko.check

local VAULT = ko.SCRATCH .. "/vault"

local BOOK = { title = "Critique of Pure Reason", authors = "Immanuel Kant",
    md5 = "abc123def456", file = "/books/kant.epub" }

local function freshVault()
    os.execute("rm -rf " .. VAULT)
end

local function readFile(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local body = file:read("*a")
    file:close()
    return body
end

local function fileExists(path)
    local file = io.open(path, "r")
    if file then file:close() return true end
    return false
end

--- One annotation as KOReader would hand it over. A field set to false in
--- `fields` is removed, which pairs() alone cannot express.
local function annotation(index, fields)
    local out = {
        datetime = string.format("2026-07-29 10:00:%02d", index),
        text = "passage " .. index,
        note = "my note " .. index,
        chapter = "Chapter 1",
        pageno = index * 10,
    }
    for key, value in pairs(fields or {}) do
        out[key] = value ~= false and value or nil
    end
    return out
end

local function loadModules()
    return require("lunote_history"), require("lunote_obsidian")
end

print("a book's note")
ko.reset()
freshVault()
local History, Obsidian = loadModules()

check("no vault configured by default", Obsidian.isConfigured() == false)
check("export without a vault is reported, not raised", (function()
    local written, err = Obsidian.exportPending()
    return written == 0 and err ~= nil
end)())

local vault, vault_err = Obsidian.setVaultPath(VAULT .. "/")
check("setting the vault trims the trailing slash", vault == VAULT, tostring(vault) .. " " .. tostring(vault_err))
check("configured now", Obsidian.isConfigured() == true)
check("the notes folder is created up front", fileExists(VAULT .. "/Lunote") or ko.isDir ~= nil)

History.mirrorAnnotations(BOOK, {
    annotation(1),
    annotation(2, { note = false }),
})
History.startConversation{
    book = BOOK, kind = "explain", highlight = "passage 1",
    chapter = "Chapter 1", pageno = 10,
    annotation_datetime = "2026-07-29 10:00:01",
    model = "google/gemini-2.5-flash-lite",
    messages = {
        { role = "user", content = "passage 1" },
        { role = "assistant", content = "Kant argues that duty precedes consequence.\n\nA second paragraph." },
    },
}

check("one book is pending", Obsidian.countPending() == 1, Obsidian.countPending())

local written, export_err = Obsidian.exportPending()
check("one note written", written == 1 and export_err == nil, tostring(written) .. " " .. tostring(export_err))
check("nothing pending afterwards", Obsidian.countPending() == 0, Obsidian.countPending())

local NOTE_PATH = VAULT .. "/Lunote/Critique of Pure Reason.md"
local note = readFile(NOTE_PATH)
check("the note is named after the book", note ~= nil, NOTE_PATH)
note = note or ""

check("frontmatter opens the file", note:sub(1, 4) == "---\n", note:sub(1, 40))
check("frontmatter carries the title", note:find('title: "Critique of Pure Reason"', 1, true) ~= nil)
check("frontmatter carries the author", note:find('author: "Immanuel Kant"', 1, true) ~= nil)
check("frontmatter counts the highlights", note:find("highlights: 2", 1, true) ~= nil)
check("frontmatter counts the explanations", note:find("explanations: 1", 1, true) ~= nil)
check("frontmatter carries the book uuid", note:find("lunote_book: \"", 1, true) ~= nil)
check("the note is tagged", note:find("  - lunote", 1, true) ~= nil)
check("the book is the H1", note:find("\n# Critique of Pure Reason\n", 1, true) ~= nil)
check("the chapter is a heading", note:find("\n## Chapter 1\n", 1, true) ~= nil)

check("the highlight is quoted", note:find("\n> passage 1\n", 1, true) ~= nil)
check("the highlight carries a stable block id",
    note:find("^lunote-20260729100001", 1, true) ~= nil)
check("your own note is a callout", note:find("> [!note] Your note\n> my note 1", 1, true) ~= nil)
check("a highlight without a note gets no note callout",
    select(2, note:gsub("%[!note%]", "")) == 1, select(2, note:gsub("%[!note%]", "")))

check("the explanation is a collapsed callout",
    note:find("> [!abstract]- Explanation · google/gemini-2.5-flash-lite", 1, true) ~= nil)
check("the explanation body is quoted",
    note:find("> Kant argues that duty precedes consequence.", 1, true) ~= nil)
check("a blank line inside a callout keeps its marker", note:find("\n>\n", 1, true) ~= nil)
check("the second paragraph stays inside the callout",
    note:find("> A second paragraph.", 1, true) ~= nil)
-- The highlight is already quoted above the callout; repeating it as the first
-- turn of the transcript would say the same thing twice.
check("the transcript does not repeat the highlight",
    select(2, note:gsub("passage 1", "")) == 1, select(2, note:gsub("passage 1", "")))
check("no AI note marker leaks into the vault",
    note:find("— Lunote —", 1, true) == nil)

print("\nfollow-up questions")
History.startConversation{
    book = BOOK, kind = "explain", highlight = "passage 2",
    annotation_datetime = "2026-07-29 10:00:02",
    messages = {
        { role = "user", content = "passage 2" },
        { role = "assistant", content = "The first answer." },
    },
}
local conversations = History.listConversations(1) or {}
History.appendMessages(conversations[1].id, {
    { role = "user", content = "Is that the same as the golden rule?" },
    { role = "assistant", content = "Not quite." },
})
check("a follow-up makes the book pending again", Obsidian.countPending() == 1)

Obsidian.exportPending()
note = readFile(NOTE_PATH) or ""
check("the question is attributed", note:find("> **You:** Is that the same as the golden rule?", 1, true) ~= nil)
check("the reply follows it", note:find("> Not quite.", 1, true) ~= nil)
check("an explanation with no model gets a plain title",
    note:find("> [!abstract]- Explanation\n", 1, true) ~= nil)

print("\ndeleting an explanation rewrites the note")
local before_delete = History.listConversations(1) or {}
History.deleteConversation(before_delete[1].id)
check("the book is pending after a delete", Obsidian.countPending() == 1)
Obsidian.exportPending()
note = readFile(NOTE_PATH) or ""
check("the deleted explanation is gone from the vault",
    note:find("Is that the same as the golden rule?", 1, true) == nil)

print("\nreading order")
ko.reset()
freshVault()
History, Obsidian = loadModules()
History.setState("obsidian_vault", VAULT)

-- Deliberately mirrored back to front, and more than one page of them, so the
-- ordering cannot come from the rowids or from a single query.
local backwards = {}
for index = 30, 1, -1 do backwards[#backwards + 1] = annotation(index) end
History.mirrorAnnotations(BOOK, backwards)
Obsidian.exportPending()
note = readFile(VAULT .. "/Lunote/Critique of Pure Reason.md") or ""

local order, previous_ok = {}, true
for page in note:gmatch("### p%. (%d+)") do order[#order + 1] = tonumber(page) end
check("every highlight made it into the note", #order == 30, #order)
for index = 2, #order do
    if order[index] <= order[index - 1] then previous_ok = false end
end
check("highlights are in page order across pages", previous_ok, table.concat(order, ","))

print("\nbooks with nothing in them")
ko.reset()
freshVault()
History, Obsidian = loadModules()
History.setState("obsidian_vault", VAULT)
-- Mirroring runs on every close, so simply opening a book creates a row here
History.mirrorAnnotations({ title = "Just Browsing", authors = "Nobody", md5 = "empty" }, {})
check("an empty book is not pending", Obsidian.countPending() == 0, Obsidian.countPending())
written = Obsidian.exportPending()
check("and nothing is written for it", written == 0
    and not fileExists(VAULT .. "/Lunote/Just Browsing.md"))

print("\nexplanations with no highlight to sit under")
ko.reset()
freshVault()
History, Obsidian = loadModules()
History.setState("obsidian_vault", VAULT)
History.mirrorAnnotations(BOOK, { annotation(1) })
-- A scanned PDF can hand back a selection with no positions: the explanation is
-- recorded but there is no annotation for it to hang off.
History.startConversation{
    book = BOOK, kind = "explain", highlight = "an unanchored passage",
    messages = {
        { role = "user", content = "an unanchored passage" },
        { role = "assistant", content = "Explained anyway." },
    },
}
Obsidian.exportPending()
note = readFile(VAULT .. "/Lunote/Critique of Pure Reason.md") or ""
check("unanchored explanations get their own section",
    note:find("## Explanations without a highlight", 1, true) ~= nil)
check("the passage is still quoted", note:find("> an unanchored passage", 1, true) ~= nil)
check("and so is the explanation", note:find("> Explained anyway.", 1, true) ~= nil)

print("\nnaming")
ko.reset()
freshVault()
History, Obsidian = loadModules()
History.setState("obsidian_vault", VAULT)

check("path separators are stripped from a title",
    Obsidian.sanitize("Notes: 1/2 [draft]") == "Notes 1 2 draft",
    Obsidian.sanitize("Notes: 1/2 [draft]"))
check("a title of nothing but punctuation has no name",
    Obsidian.sanitize("///") == nil)

local SHARED = { title = "Essays", authors = "Author One", md5 = "one" }
local OTHER = { title = "Essays", authors = "Author Two", md5 = "two" }
History.mirrorAnnotations(SHARED, { annotation(1) })
History.mirrorAnnotations(OTHER, { annotation(2) })
Obsidian.exportPending()
check("the first book takes the plain name", fileExists(VAULT .. "/Lunote/Essays.md"))
check("a second book with the same title is disambiguated",
    fileExists(VAULT .. "/Lunote/Essays — Author Two.md"))

-- A book keeps the file it was first written to, so re-exporting overwrites
-- rather than leaving a second copy behind.
History.mirrorAnnotations(SHARED, { annotation(1), annotation(3) })
Obsidian.exportPending()
local essays = readFile(VAULT .. "/Lunote/Essays.md") or ""
check("re-exporting rewrites the same file", essays:find("passage 3", 1, true) ~= nil)
check("and does not leave a second copy",
    not fileExists(VAULT .. "/Lunote/Essays — Author One.md"))
check("no working files are left in the vault",
    not fileExists(VAULT .. "/Lunote/Essays.md.lunote-tmp")
    and not fileExists(VAULT .. "/Lunote/Essays.md.lunote-old"))

print("\nchanging the folder")
History.setState("obsidian_folder", "Reading/Books")
History.markAllForObsidian()
Obsidian.exportPending()
check("notes follow the folder setting",
    fileExists(VAULT .. "/Reading/Books/Essays.md"))

print("\nfailure handling")
ko.reset()
freshVault()
History, Obsidian = loadModules()
History.mirrorAnnotations(BOOK, { annotation(1) })
-- A vault on an SD card that is no longer there: /proc is real, and not writable
History.setState("obsidian_vault", "/proc/lunote-nonexistent")
written, export_err = Obsidian.exportPending()
check("an unwritable vault is reported, not raised", written == 0 and export_err ~= nil, export_err)
check("the book stays pending for the next attempt", Obsidian.countPending() == 1)
check("no half-written note is left behind",
    not fileExists("/proc/lunote-nonexistent/Lunote/Critique of Pure Reason.md"))

History.setState("obsidian_vault", VAULT)
written, export_err = Obsidian.exportPending()
check("pointing at a good folder finishes the job", written == 1 and export_err == nil, export_err)

print("\nclosing a book writes its note")
ko.reset()
freshVault()
History, Obsidian = loadModules()
History.setState("obsidian_vault", VAULT)

local ui = {
    annotation = { annotations = { annotation(1), annotation(2) } },
    document = {
        file = "/books/kant.epub",
        getProps = function() return { title = BOOK.title, authors = BOOK.authors } end,
    },
    menu = { registerToMainMenu = function() end },
    handleEvent = function() end,
    highlight = { addToHighlightDialog = function() end, onClose = function() end },
}
local plugin = dofile(ko.PLUGIN .. "/main.lua")
local instance = plugin:new{ ui = ui, view = {}, document = ui.document }

check("auto export is on once a vault is set", Obsidian.isAutoExportEnabled() == true)
instance:onCloseDocument()
note = readFile(VAULT .. "/Lunote/Critique of Pure Reason.md")
check("closing the book wrote its note", note ~= nil)
check("with the highlights in it", note and note:find("> passage 2", 1, true) ~= nil)
check("and nothing left pending", Obsidian.countPending() == 0)

print("\nauto export can be turned off")
freshVault()
Obsidian.setAutoExport(false)
check("the setting sticks", Obsidian.isAutoExportEnabled() == false)
table.insert(ui.annotation.annotations, annotation(3))
instance:onCloseDocument()
check("closing writes nothing when it is off",
    not fileExists(VAULT .. "/Lunote/Critique of Pure Reason.md"))
check("but the book is still pending for a manual export", Obsidian.countPending() == 1)

print("\nthe menu")
local items = {}
instance:addToMainMenu(items)
local submenu
for _index, entry in ipairs(items.lunote.sub_item_table) do
    if entry.text == "Obsidian vault" then submenu = entry.sub_item_table end
end
check("the vault has its own submenu", submenu ~= nil)
submenu = submenu or {}
check("the Obsidian address is offered first",
    submenu[1] and submenu[1].text_func() == "Connect to Obsidian…",
    submenu[1] and submenu[1].text_func())
check("the folder is shown once set", submenu[3] and submenu[3].text_func():find(VAULT, 1, true) ~= nil,
    submenu[3] and submenu[3].text_func())
check("the pending count is shown", submenu[4] and submenu[4].text_func():find("(1)", 1, true) ~= nil,
    submenu[4] and submenu[4].text_func())
check("the write-on-close toggle reflects the setting",
    submenu[5] and submenu[5].checked_func() == false)
check("writing is disabled with nowhere to write to", (function()
    Obsidian.forgetVault()
    return submenu[4].enabled_func() == false
end)())

-- Pushing to Obsidian over the network ---------------------------------------

print("\nthe Obsidian address")
ko.reset()
History, Obsidian = loadModules()

check("a bare address gets HTTPS and the default port",
    Obsidian.normaliseServer("192.168.1.20") == "https://192.168.1.20:27124",
    Obsidian.normaliseServer("192.168.1.20"))
check("a port that was given is kept",
    Obsidian.normaliseServer("192.168.1.20:27123") == "https://192.168.1.20:27123")
check("plain HTTP is left alone, for the insecure port",
    Obsidian.normaliseServer("http://192.168.1.20:27123") == "http://192.168.1.20:27123")
check("a trailing slash is trimmed",
    Obsidian.normaliseServer("https://vault.example.com/") == "https://vault.example.com")

check("an address on its own is not enough", (function()
    History.setState("obsidian_url", "https://192.168.1.20:27124")
    return Obsidian.isServerConfigured() == false
end)())
check("an address and a key are", (function()
    Obsidian.setServer("192.168.1.20", "0123456789abcdef")
    return Obsidian.isServerConfigured() == true
end)())
check("the key is not treated as a vault folder", Obsidian.getVaultPath() == nil)
check("a missing key is refused", (function()
    local ok, err = Obsidian.setServer("192.168.1.20", "  ")
    return ok == nil and err ~= nil
end)())

print("\npushing a note to Obsidian")
ko.reset()
freshVault()
History, Obsidian = loadModules()
Obsidian.setServer("192.168.1.20", "secret-key")
History.mirrorAnnotations(BOOK, { annotation(1) })
History.startConversation{
    book = BOOK, kind = "explain", highlight = "passage 1",
    annotation_datetime = "2026-07-29 10:00:01", model = "test-model",
    messages = {
        { role = "user", content = "passage 1" },
        { role = "assistant", content = "Because Kant says so." },
    },
}

written, export_err = Obsidian.exportPending()
check("the note is pushed", written == 1 and export_err == nil, tostring(export_err))
local put = ko.http.requests[1]
check("one request was made", #ko.http.requests == 1, #ko.http.requests)
check("it is a PUT", put and put.method == "PUT", put and put.method)
check("to the vault path, percent-encoded",
    put and put.url == "https://192.168.1.20:27124/vault/Lunote/Critique%20of%20Pure%20Reason.md",
    put and put.url)
check("with the API key", put and put.headers["Authorization"] == "Bearer secret-key",
    put and put.headers["Authorization"])
check("as markdown", put and put.headers["Content-Type"] == "text/markdown")
check("with a length", put and put.headers["Content-Length"] == tostring(#put.body),
    put and put.headers["Content-Length"])
check("the body is the note", put and put.body:find("# Critique of Pure Reason", 1, true) ~= nil)
check("with the explanation in it", put and put.body:find("> Because Kant says so.", 1, true) ~= nil)
check("nothing is left pending", Obsidian.countPending() == 0, Obsidian.countPending())

local before_calls = #ko.http.requests
Obsidian.exportPending()
check("a second push sends nothing", #ko.http.requests == before_calls)

print("\nwhen Obsidian says no")
ko.reset()
History, Obsidian = loadModules()
Obsidian.setServer("192.168.1.20", "wrong-key")
History.mirrorAnnotations(BOOK, { annotation(1) })

ko.http.status = 401
written, export_err = Obsidian.exportPending()
check("a rejected key is explained, not raised", written == 0
    and export_err ~= nil and export_err:find("API key", 1, true) ~= nil, export_err)
check("the book stays pending", Obsidian.countPending() == 1)

ko.http.status = 200
ko.http.fail_after = 0 -- as if the laptop were asleep
written, export_err = Obsidian.exportPending()
check("an unreachable Obsidian is reported", written == 0 and export_err ~= nil, export_err)
check("and the book is still pending", Obsidian.countPending() == 1)

ko.http.fail_after = nil
written, export_err = Obsidian.exportPending()
check("it goes out once Obsidian is back", written == 1 and export_err == nil, export_err)

print("\ntesting the connection")
ko.reset()
History, Obsidian = loadModules()
Obsidian.setServer("192.168.1.20", "secret-key")
ko.http.response = { service = "Obsidian Local REST API", authenticated = true,
    versions = { obsidian = "1.12.4" } }
local connected, detail = Obsidian.testConnection()
check("a good connection reports the service", connected == true
    and detail:find("Obsidian Local REST API", 1, true) ~= nil, detail)
check("the test is a plain GET", ko.http.requests[1].method == "GET"
    and ko.http.requests[1].url == "https://192.168.1.20:27124/")

ko.http.response = { authenticated = false }
connected, detail = Obsidian.testConnection()
check("a rejected key is caught by the test", connected == nil and detail ~= nil, detail)

print("\nboth destinations at once")
ko.reset()
freshVault()
History, Obsidian = loadModules()
History.setState("obsidian_vault", VAULT)
Obsidian.setServer("192.168.1.20", "secret-key")
History.mirrorAnnotations(BOOK, { annotation(1) })
check("both destinations are configured", #Obsidian.destinations() == 2)
check("the book counts once, not twice", Obsidian.countPending() == 1, Obsidian.countPending())

written, export_err = Obsidian.exportPending()
check("one book, one note in the summary", written == 1 and export_err == nil, export_err)
check("the file was written", fileExists(VAULT .. "/Lunote/Critique of Pure Reason.md"))
check("and Obsidian was sent the same path",
    ko.http.requests[1].url:find("/vault/Lunote/Critique%20of%20Pure%20Reason.md", 1, true) ~= nil,
    ko.http.requests[1].url)
check("nothing left pending anywhere", Obsidian.countPending() == 0)

print("\none destination failing does not undo the other")
freshVault()
History.mirrorAnnotations(BOOK, { annotation(1), annotation(2) })
ko.http.fail_after = 0
written, export_err = Obsidian.exportPending()
check("the failure is reported", export_err ~= nil, export_err)
check("the file destination still got its note",
    fileExists(VAULT .. "/Lunote/Critique of Pure Reason.md"))
check("the book is still pending, for Obsidian", Obsidian.countPending() == 1)

ko.http.fail_after = nil
local requests_before = #ko.http.requests
written, export_err = Obsidian.exportPending()
check("retrying sends only what is owed", #ko.http.requests - requests_before == 1,
    #ko.http.requests - requests_before)
check("and now everything is delivered", Obsidian.countPending() == 0)

print("\nclosing a book does not wait on wifi")
ko.reset()
freshVault()
History, Obsidian = loadModules()
History.setState("obsidian_vault", VAULT)
Obsidian.setServer("192.168.1.20", "secret-key")

local closing_ui = {
    annotation = { annotations = { annotation(1) } },
    document = {
        file = "/books/kant.epub",
        getProps = function() return { title = BOOK.title, authors = BOOK.authors } end,
    },
    menu = { registerToMainMenu = function() end },
    handleEvent = function() end,
    highlight = { addToHighlightDialog = function() end, onClose = function() end },
}
local closing_plugin = dofile(ko.PLUGIN .. "/main.lua")
closing_plugin:new{ ui = closing_ui, view = {}, document = closing_ui.document }
    :onCloseDocument()

check("the note is on disk", fileExists(VAULT .. "/Lunote/Critique of Pure Reason.md"))
check("but nothing was sent over the network", #ko.http.requests == 0, #ko.http.requests)
check("Obsidian is still owed the note", Obsidian.countPending() == 1)

print("\none sync, both destinations")
ko.reset()
freshVault()
History, Obsidian = loadModules()
local Sync = require("lunote_sync")
History.setState("obsidian_vault", VAULT)
Obsidian.setServer("192.168.1.20", "secret-key")
History.setState("token", "web-app-token")
History.mirrorAnnotations(BOOK, { annotation(1) })

check("the count covers both", Sync.countOutstanding() == 2, Sync.countOutstanding())
ko.http.response = { accepted = 1 }
local summary, sync_err
Sync.runEverything{ done = function(s, e) summary, sync_err = s, e end }
check("no error", sync_err == nil, sync_err)
check("both destinations are reported", #summary == 2, summary and #summary)
check("the web app got its records", summary[1]:find("record", 1, true) ~= nil, summary[1])
check("the vault got its note", summary[2]:find("note", 1, true) ~= nil, summary[2])
check("the note is in the folder", fileExists(VAULT .. "/Lunote/Critique of Pure Reason.md"))
check("nothing is outstanding afterwards", Sync.countOutstanding() == 0, Sync.countOutstanding())

print("\nsyncing with only one destination set up")
ko.reset()
freshVault()
History, Obsidian = loadModules()
Sync = require("lunote_sync")
History.mirrorAnnotations(BOOK, { annotation(1) })
check("nowhere to sync to yet", Sync.hasDestination() == false)
Obsidian.setServer("192.168.1.20", "secret-key")
check("Obsidian alone is a destination", Sync.hasDestination() == true)
Sync.runEverything{ done = function(s, e) summary, sync_err = s, e end }
check("an unpaired device still writes to Obsidian", sync_err == nil and #summary == 1, sync_err)
check("and the note was pushed", #ko.http.requests == 1 and ko.http.requests[1].method == "PUT")

ko.summary()
