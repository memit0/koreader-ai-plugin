--[[--
Puts your reading into an Obsidian vault: **one note per book**, holding every
highlight from that book, the note you wrote on it and the explanations Lunote
generated, in reading order.

There are two ways a note can get there, and they can be used together:

* **over the network**, to Obsidian's Local REST API — the same shape as the web
  app sync, so `Sync` pushes to both and a book already delivered is a no-op;
* **into a folder**, when the vault (or something that syncs it) is on the
  device itself. This one needs no network at all and runs when a book closes.

Four rules shape this file:

1. **Nothing raises.** An Obsidian that is asleep, or a vault on an SD card that
   is no longer there, has to fail as a message rather than as a dead reader.
2. **The note is generated, never merged into.** A book's note is rewritten whole
   from the store, so it always says exactly what the device holds. Your own
   writing belongs in your own notes, which can link to the block ids below.
3. **Each destination keeps its own outbox.** Writing the file must not tell the
   network push that Obsidian has the note, or the other way round.
4. **Nothing loads a whole library.** Highlights are read a page at a time; the
   file destination streams them straight out, and only the network destination
   buffers a note, because a request needs its length up front.
]]
local History = require("lunote_history")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local _ = require("gettext")

local Env = require("lunote_env")

local CONFIGURATION = Env.loadOptional("lunote_config")

local Obsidian = {}

local PAGE_SIZE = 25
local DEFAULT_FOLDER = "Lunote"
-- What the Local REST API plugin listens on out of the box: HTTPS on 27124,
-- with plain HTTP on 27123 if the user turns it on.
local DEFAULT_PORT = 27124
-- Written next to the note and renamed over it, so an interrupted write cannot
-- leave a half-finished note in the vault.
local TMP_SUFFIX = ".lunote-tmp"
-- Long enough for any real title, short enough to survive filesystems that cap a
-- name at 255 bytes once the extension and a disambiguating suffix are added.
local MAX_NAME_BYTES = 120

local function feature(name)
    return CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features[name]
end

-- Filesystem ----------------------------------------------------------------
-- KOReader bundles LuaFileSystem under its own name. Everything here works
-- without it too, because the simulator and the test suite run on a plain Lua.

local lfs_module

local function filesystem()
    if lfs_module == nil then
        lfs_module = false
        for _, name in ipairs({ "libs/libkoreader-lfs", "lfs" }) do
            local ok, loaded = pcall(require, name)
            if ok and type(loaded) == "table" and loaded.mkdir then
                lfs_module = loaded
                break
            end
        end
    end
    return lfs_module or nil
end

local function shellQuote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function pathExists(path)
    local fs = filesystem()
    if fs then return fs.attributes(path, "mode") ~= nil end
    -- Renaming a path onto itself succeeds only if it is there, and says nothing
    -- about whether it is a file or a directory — which is all we need.
    return os.rename(path, path) == true
end

Obsidian.pathExists = pathExists

--- mkdir -p, one component at a time. Returns true, or nil plus a message.
local function makePath(path)
    if pathExists(path) then return true end
    local fs = filesystem()
    if fs then
        local built = path:sub(1, 1) == "/" and "" or "."
        for component in path:gmatch("[^/]+") do
            built = built .. "/" .. component
            if not pathExists(built) then
                local ok, err = fs.mkdir(built)
                -- Another writer getting there first is a success, not a failure
                if not ok and not pathExists(built) then
                    return nil, "Could not create " .. built .. ": " .. tostring(err)
                end
            end
        end
        return true
    end
    os.execute("mkdir -p " .. shellQuote(path))
    if pathExists(path) then return true end
    return nil, "Could not create " .. path
end

-- Configuration --------------------------------------------------------------
-- Set from the menu on the device, since editing files on an e-reader is
-- miserable; lunote_config.lua and .env are there for anyone installing by hand.

local function trim(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text
end

local function trimPath(path)
    path = trim(path)
    if not path then return nil end
    -- A trailing slash would double up when joined, and "/" itself is not a vault
    path = path:gsub("/+$", "")
    if path == "" then return nil end
    return path
end

--- Accepts what someone will actually type on an e-reader: `192.168.1.20`,
--- `192.168.1.20:27124`, or a full URL. A bare address gets HTTPS on the port
--- the Local REST API plugin shows on its settings screen.
local function normaliseServer(address)
    address = trim(address)
    if not address then return nil end
    if not address:match("^https?://") then
        if not address:match(":%d+$") then address = address .. ":" .. DEFAULT_PORT end
        address = "https://" .. address
    end
    return (address:gsub("/+$", ""))
end

Obsidian.normaliseServer = normaliseServer

--- The address of the Obsidian serving the Local REST API, or nil.
function Obsidian.getServerUrl()
    local stored = History.getState("obsidian_url")
    if stored and stored ~= "" then return normaliseServer(stored) end
    return normaliseServer(feature("obsidian_url") or Env.get("LUNOTE_OBSIDIAN_URL"))
end

function Obsidian.getApiKey()
    local stored = History.getState("obsidian_key")
    if stored and stored ~= "" then return stored end
    return trim(feature("obsidian_api_key") or Env.get("LUNOTE_OBSIDIAN_KEY"))
end

function Obsidian.isServerConfigured()
    return Obsidian.getServerUrl() ~= nil and Obsidian.getApiKey() ~= nil
end

--- Remembers where Obsidian is and how to authenticate to it.
function Obsidian.setServer(address, api_key)
    local url = normaliseServer(address)
    if not url then return nil, "That is not an address." end
    local key = trim(api_key)
    if not key then return nil, "The API key is missing." end
    History.setState("obsidian_url", url)
    History.setState("obsidian_key", key)
    return url
end

function Obsidian.forgetServer()
    History.setState("obsidian_url", "")
    History.setState("obsidian_key", "")
    return true
end

--- The vault root on this device, for when the vault (or a folder something else
--- syncs) lives on the e-reader. nil when only the network destination is used.
function Obsidian.getVaultPath()
    local stored = History.getState("obsidian_vault")
    if stored and stored ~= "" then return trimPath(stored) end
    return trimPath(feature("obsidian_vault") or Env.get("LUNOTE_OBSIDIAN_VAULT"))
end

--- The folder inside the vault the notes go in. "" means the vault root.
function Obsidian.getFolder()
    local stored = History.getState("obsidian_folder")
    local folder = stored
    if folder == nil or folder == "" then
        folder = feature("obsidian_folder") or Env.get("LUNOTE_OBSIDIAN_FOLDER") or DEFAULT_FOLDER
    end
    folder = tostring(folder):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^/+", ""):gsub("/+$", "")
    return folder
end

--- Points the plugin at a vault folder. Creating the notes folder now rather
--- than at the first export is what turns a typo into an error message while the
--- user is still looking at the dialog.
function Obsidian.setVaultPath(path)
    local vault = trimPath(path)
    if not vault then return nil, "That is not a folder path." end
    History.setState("obsidian_vault", vault)
    local folder = Obsidian.getFolder()
    local ok, err = makePath(folder ~= "" and (vault .. "/" .. folder) or vault)
    if not ok then return nil, err end
    return vault
end

function Obsidian.forgetVault()
    History.setState("obsidian_vault", "")
    return true
end

--- Whether the path looks like a vault Obsidian already knows about. Only used
--- to warn: a brand new folder is a perfectly good vault once Obsidian opens it.
function Obsidian.looksLikeVault(path)
    local vault = trimPath(path)
    return vault ~= nil and pathExists(vault .. "/.obsidian")
end

--- Where a book's note is sent, in the order it is written. Both, either or
--- neither may be configured.
function Obsidian.destinations()
    local out = {}
    if Obsidian.getVaultPath() then out[#out + 1] = "file" end
    if Obsidian.isServerConfigured() then out[#out + 1] = "remote" end
    return out
end

function Obsidian.isConfigured()
    return #Obsidian.destinations() > 0
end

function Obsidian.isAutoExportEnabled()
    local stored = History.getState("obsidian_auto")
    if stored == "0" then return false end
    if stored == "1" then return true end
    -- Unset: writing the note when a book closes is the point of the folder
    -- destination, so it is on as soon as one is configured.
    return feature("obsidian_auto_export") ~= false
end

function Obsidian.setAutoExport(enabled)
    History.setState("obsidian_auto", enabled and "1" or "0")
    return enabled
end

--- How many books are waiting, counted across whatever is configured.
function Obsidian.countPending()
    local destinations = Obsidian.destinations()
    if #destinations == 0 then return 0 end
    local which = #destinations > 1 and "any" or destinations[1]
    return History.countObsidianPending(which) or 0
end

-- Markdown -------------------------------------------------------------------

local function collapse(text)
    return (tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- A double-quoted YAML scalar: safe for titles containing colons, quotes, #, or
--- anything else that would otherwise end the value early.
local function yaml(value)
    return '"' .. collapse(value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- Every line of `text` behind `prefix`, so multi-line prose can sit inside a
--- blockquote or a callout. Blank lines keep the bare marker: dropping it would
--- end the callout at the first paragraph break.
local function prefixLines(text, prefix)
    local body = tostring(text or ""):gsub("\r\n", "\n"):gsub("%s+$", "")
    if body == "" then return nil end
    local marker = (prefix:gsub("%s+$", ""))
    local out = {}
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line:match("%S") and (prefix .. line) or marker
    end
    return table.concat(out, "\n")
end

-- A stable anchor for the highlight, derived from the annotation's datetime —
-- which is its id within the book. Rewriting the note keeps the same ids, so a
-- link from one of your own notes to a particular highlight survives.
local function blockId(datetime)
    local id = tostring(datetime or ""):gsub("[^%w]", "")
    if id == "" then return nil end
    return "^lunote-" .. id
end

--- Cuts to at most `limit` bytes without splitting a UTF-8 sequence in half.
local function truncateBytes(text, limit)
    if #text <= limit then return text end
    local cut = limit
    while cut > 1 do
        local following = text:byte(cut + 1)
        if not following or following < 128 or following >= 192 then break end
        cut = cut - 1
    end
    return (text:sub(1, cut):gsub("%s+$", ""))
end

-- Characters no filesystem or Obsidian will take in a name. `#`, `^`, `[` and
-- `]` are legal on disk but mean something in a wiki link, so they go too.
local FORBIDDEN = '[%[%]#%^|\\/:%*%?"<>%c]'

local function sanitize(name)
    local out = collapse(tostring(name or ""):gsub(FORBIDDEN, " "))
    -- A leading dot hides the note; a trailing dot or space is invalid on some
    -- filesystems and silently stripped by others.
    out = out:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    if out == "" then return nil end
    return truncateBytes(out, MAX_NAME_BYTES)
end

Obsidian.sanitize = sanitize

local function join(folder, name)
    if folder == "" then return name end
    return folder .. "/" .. name
end

--- Where this book's note goes, relative to the vault root — the same path
--- whichever destination delivers it. A book keeps the path it was first written
--- to, so renaming a book in KOReader does not scatter second copies through the
--- vault; only a change of folder moves it.
local function relativePathFor(book)
    local folder = Obsidian.getFolder()
    local stored = book.obsidian_path
    if stored and stored ~= "" then
        local stored_folder = stored:match("^(.*)/[^/]*$") or ""
        if stored_folder == folder then return stored end
    end

    local base = sanitize(book.title) or _("Untitled")
    local candidates = { base }
    local author = sanitize(book.authors)
    if author then candidates[#candidates + 1] = base .. " — " .. author end
    local md5 = tostring(book.md5 or ""):sub(1, 8)
    if md5 ~= "" then candidates[#candidates + 1] = base .. " (" .. md5 .. ")" end
    candidates[#candidates + 1] = base .. " (" .. tostring(book.id) .. ")"

    for _index, candidate in ipairs(candidates) do
        local relative = join(folder, candidate .. ".md")
        if not History.isObsidianPathTaken(relative, book.id) then return relative end
    end
    return join(folder, base .. " (" .. tostring(book.id) .. ").md")
end

Obsidian.relativePathFor = relativePathFor

local function headingFor(item)
    local parts = {}
    if item.pageno and tonumber(item.pageno) then
        parts[#parts + 1] = _("p. ") .. tostring(math.floor(tonumber(item.pageno)))
    end
    -- The annotation datetime is "YYYY-MM-DD HH:MM:SS"; the day is the useful part
    local day = tostring(item.datetime or ""):match("^(%d%d%d%d%-%d%d%-%d%d)")
    if day then parts[#parts + 1] = day end
    if #parts == 0 then return _("Highlight") end
    return table.concat(parts, " · ")
end

-- The first user turn is the highlight itself, already quoted above the callout,
-- and the first assistant turn is the explanation. Anything after that is the
-- follow-up conversation.
local function conversationBody(conversation)
    local out = {}
    for index, message in ipairs(conversation.messages or {}) do
        if index == 1 and message.role == "user" then
            -- skip: this is the highlight
        elseif message.role == "user" then
            out[#out + 1] = "**" .. _("You:") .. "** " .. collapse(message.content)
        else
            out[#out + 1] = tostring(message.content or "")
        end
    end
    return table.concat(out, "\n\n")
end

local function calloutTitle(conversation)
    local label = conversation.kind == "translate" and _("Translation") or _("Explanation")
    if conversation.model and conversation.model ~= "" then
        return label .. " · " .. collapse(conversation.model)
    end
    return label
end

--- The callout an explanation is rendered as: collapsed by default, so a note
--- with fifty highlights still reads as a list of passages.
local function conversationMarkdown(conversation)
    local body = prefixLines(conversationBody(conversation), "> ")
    if not body then return nil end
    return "> [!abstract]- " .. calloutTitle(conversation) .. "\n" .. body
end

--- Renders the whole note into `write`, a sink taking one string at a time.
local function writeBook(write, book)
    write("---\n")
    write("title: " .. yaml(book.title ~= "" and book.title or _("Untitled")) .. "\n")
    if book.authors and book.authors ~= "" then
        write("author: " .. yaml(book.authors) .. "\n")
    end
    write("highlights: " .. tostring(book.n_items) .. "\n")
    write("explanations: " .. tostring(book.n_conversations) .. "\n")
    write("updated: " .. os.date("%Y-%m-%d %H:%M") .. "\n")
    -- The record uuid, so a note can be traced back to the device that wrote it
    write("lunote_book: " .. yaml(book.uuid) .. "\n")
    write("tags:\n  - lunote\n")
    write("---\n\n")

    write("# " .. collapse(book.title ~= "" and book.title or _("Untitled")) .. "\n")
    if book.authors and book.authors ~= "" then
        write("\n*" .. collapse(book.authors) .. "*\n")
    end

    local chapter, wrote_heading = nil, false
    local cursor
    while true do
        local page = History.getObsidianItems(book.id, cursor, PAGE_SIZE)
        if not page or #page.records == 0 then break end

        for _index, item in ipairs(page.records) do
            local item_chapter = collapse(item.chapter)
            if item_chapter == "" then item_chapter = _("Highlights") end
            if item_chapter ~= chapter then
                chapter = item_chapter
                wrote_heading = true
                write("\n## " .. chapter .. "\n")
            end

            write("\n### " .. headingFor(item) .. "\n\n")
            local quoted = prefixLines(item.text, "> ")
            if quoted then
                write(quoted .. "\n")
                -- A block id for a multi-line block goes on a line of its own,
                -- with a blank line either side, or it is read as part of the
                -- quote instead of as an anchor for it.
                local anchor = blockId(item.datetime)
                if anchor then write("\n" .. anchor .. "\n") end
            end

            local note = prefixLines(item.note, "> ")
            if note then
                write("\n> [!note] " .. _("Your note") .. "\n" .. note .. "\n")
            end

            for _i, conversation in ipairs(History.getConversationsForAnnotation(book.id, item.datetime) or {}) do
                local rendered = conversationMarkdown(conversation)
                if rendered then write("\n" .. rendered .. "\n") end
            end
        end

        if #page.records < PAGE_SIZE then break end
        cursor = page.cursor
    end

    -- Explanations with no highlight to sit under, so nothing is silently dropped
    local orphan_cursor, wrote_orphan_heading = 0, false
    while true do
        local page = History.getUnanchoredConversations(book.id, orphan_cursor, PAGE_SIZE)
        if not page or #page.records == 0 then break end

        for _index, conversation in ipairs(page.records) do
            local rendered = conversationMarkdown(conversation)
            if rendered then
                if not wrote_orphan_heading then
                    wrote_orphan_heading = true
                    write("\n## " .. _("Explanations without a highlight") .. "\n")
                end
                write("\n### " .. headingFor{ pageno = conversation.pageno,
                    datetime = conversation.created_at and os.date("%Y-%m-%d",
                        conversation.created_at) } .. "\n\n")
                local quoted = prefixLines(conversation.highlight, "> ")
                if quoted then write(quoted .. "\n\n") end
                write(rendered .. "\n")
            end
        end

        if #page.records < PAGE_SIZE then break end
        orphan_cursor = page.cursor
    end

    if not (wrote_heading or wrote_orphan_heading) then
        write("\n" .. _("No highlights yet.") .. "\n")
    end
end

--- The whole note as one string. Only the network destination needs this: a
--- request has to know its length, so that note is held in memory for as long as
--- it takes to send it, one book at a time.
local function renderNote(book)
    local chunks = {}
    local ok, err = pcall(writeBook, function(chunk) chunks[#chunks + 1] = chunk end, book)
    if not ok then return nil, tostring(err) end
    return table.concat(chunks)
end

Obsidian.renderNote = renderNote

-- Talking to Obsidian ---------------------------------------------------------

--- Percent-encodes a vault path for a URL, leaving the separators alone.
local function encodePath(path)
    return (tostring(path):gsub("[^%w%-%._~/]", function(character)
        return string.format("%%%02X", character:byte())
    end))
end

Obsidian.encodePath = encodePath

--- One request to the Local REST API. Returns the status code and the body, or
--- nil plus a message. Never raises.
local function callServer(method, path, body, content_type)
    local server = Obsidian.getServerUrl()
    if not server then return nil, "No Obsidian address is set." end

    local headers = {}
    local key = Obsidian.getApiKey()
    if key then headers["Authorization"] = "Bearer " .. key end
    if body then
        headers["Content-Type"] = content_type or "text/markdown"
        headers["Content-Length"] = tostring(#body)
    end

    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local transport = server:match("^https://") and https or http
    local ok, result, code = pcall(transport.request, {
        url = server .. path,
        method = method,
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = socketutil.table_sink(sink),
        -- Obsidian serves a self-signed certificate, on a machine whose address
        -- the reader typed in themselves. Verifying it would mean copying that
        -- certificate onto the e-reader; the API key is what actually
        -- authenticates us, and this never leaves the local network.
        verify = "none",
    })
    socketutil:reset_timeout()

    if not ok then return nil, "Could not reach Obsidian: " .. tostring(result) end
    if not result then return nil, "Could not reach Obsidian: " .. tostring(code) end
    return tonumber(code) or 0, table.concat(sink)
end

-- Worth spelling out: "HTTP 401" tells a reader nothing about what to do next.
local function describeStatus(status, response)
    if status == 401 or status == 403 then
        return "Obsidian did not accept the API key. Copy it again from the Local REST API settings."
    end
    if status == 404 then
        return "That Obsidian is running, but has no vault open for this request."
    end
    local detail = tostring(response or ""):match('"message"%s*:%s*"(.-)"')
    if detail and detail ~= "" then return detail end
    return "Obsidian returned HTTP " .. tostring(status) .. "."
end

--- Creates the book's note in the vault, or replaces the one already there.
local function putNote(relative, body)
    local status, response = callServer("PUT", "/vault/" .. encodePath(relative), body)
    if not status then return nil, response end
    if status < 200 or status > 299 then return nil, describeStatus(status, response) end
    return true
end

--- Checks the address and the key before the user goes looking for notes that
--- were never going to arrive.
function Obsidian.testConnection()
    if not Obsidian.getServerUrl() then return nil, _("No Obsidian address is set.") end
    local status, response = callServer("GET", "/")
    if not status then return nil, response end
    if status < 200 or status > 299 then return nil, describeStatus(status, response) end

    local decoded_ok, decoded = pcall(json.decode, response)
    if decoded_ok and type(decoded) == "table" then
        if decoded.authenticated == false then
            return nil, _("Obsidian answered, but did not accept the API key.")
        end
        local service = decoded.service or "Obsidian"
        local version = type(decoded.versions) == "table" and decoded.versions.obsidian
        return true, service .. (version and (" " .. tostring(version)) or "")
    end
    -- A reply we cannot parse still proves something is listening and answering
    return true, _("Obsidian answered.")
end

-- Delivering ------------------------------------------------------------------

--- Streams the note into the vault folder on this device.
local function deliverToFile(book, relative)
    local vault = Obsidian.getVaultPath()
    if not vault then return nil, "No Obsidian vault folder is set." end

    local target = vault .. "/" .. relative
    local directory = target:match("^(.*)/[^/]*$")
    if directory then
        local made, make_err = makePath(directory)
        if not made then return nil, make_err end
    end

    local temporary = target .. TMP_SUFFIX
    local file, open_err = io.open(temporary, "w")
    if not file then
        return nil, "Could not write to " .. target .. ": " .. tostring(open_err)
    end

    local wrote, write_err = pcall(writeBook, function(chunk) assert(file:write(chunk)) end, book)
    file:close()
    if not wrote then
        os.remove(temporary)
        return nil, tostring(write_err)
    end

    -- Rename cannot overwrite on every filesystem an e-reader might use, so the
    -- old note has to move out of the way first. It is kept until the new one is
    -- in place: this is someone's vault, and a failed rename must not be how they
    -- find out their note is gone.
    local backup
    if pathExists(target) then
        backup = target .. ".lunote-old"
        os.remove(backup)
        if not os.rename(target, backup) then
            os.remove(target)
            backup = nil
        end
    end

    local renamed, rename_err = os.rename(temporary, target)
    if not renamed then
        os.remove(temporary)
        if backup then os.rename(backup, target) end
        return nil, "Could not replace " .. target .. ": " .. tostring(rename_err)
    end
    if backup then os.remove(backup) end
    return true
end

--- Sends the note to Obsidian over the network.
local function deliverToServer(book, relative)
    local body, err = renderNote(book)
    if not body then return nil, err end
    return putNote(relative, body)
end

local DELIVER = { file = deliverToFile, remote = deliverToServer }

--- Writes one book's note to `destinations` (default: everything configured).
--- Returns "written", "unchanged" or "empty", or nil plus a message. `force`
--- rewrites a book whose note is already up to date.
function Obsidian.exportBook(book_id, destinations, force)
    destinations = destinations or Obsidian.destinations()
    if #destinations == 0 then return nil, "Obsidian is not set up yet." end

    local ok, result, err = pcall(function()
        local book = History.getObsidianBook(book_id)
        if not book then return nil, "That book is not in the store." end
        if book.n_items == 0 and book.n_conversations == 0 then
            -- Every book you open gets a row; only the ones you highlighted in
            -- earn a note. Clear the flags so it stops being counted as pending.
            for _index, destination in ipairs(destinations) do
                History.markObsidianWritten(book_id, destination)
            end
            return "empty"
        end

        local relative = relativePathFor(book)
        local delivered = false
        for _index, destination in ipairs(destinations) do
            if force or book.pending[destination] then
                local sent, deliver_err = DELIVER[destination](book, relative)
                if not sent then return nil, deliver_err end
                History.setObsidianPath(book_id, relative)
                History.markObsidianWritten(book_id, destination)
                delivered = true
            end
        end
        return delivered and "written" or "unchanged"
    end)

    if not ok then
        logger.warn("Lunote obsidian:", tostring(result))
        return nil, tostring(result)
    end
    if not result then return nil, err end
    return result
end

--- Writes every book that is out of date, at every destination configured.
--- `progress(n)` may return false to stop at the next book. Returns the number of
--- books written, plus a message if it stopped early. Anything that fails stays
--- flagged and is retried next time.
function Obsidian.exportPending(progress, destinations)
    destinations = destinations or Obsidian.destinations()
    if #destinations == 0 then return 0, "Obsidian is not set up yet." end

    -- Counted per book rather than per delivery, so a book going to both a folder
    -- and to Obsidian is one note in the summary, not two.
    local written, seen = 0, {}
    for _d, destination in ipairs(destinations) do
        local cursor = 0
        while true do
            local page = History.getObsidianPendingBooks(destination, cursor, PAGE_SIZE)
            if not page or #page.ids == 0 then break end

            for _index, book_id in ipairs(page.ids) do
                local outcome, err = Obsidian.exportBook(book_id, { destination })
                if not outcome then return written, err end
                if outcome == "written" and not seen[book_id] then
                    seen[book_id] = true
                    written = written + 1
                end
                if progress and progress(written) == false then return written, "cancelled" end
            end

            if #page.ids < PAGE_SIZE then break end
            cursor = page.cursor
        end
    end
    return written
end

--- Writes the note for the book just closed into the vault folder, if that is
--- switched on. The network destination is deliberately left to Sync: closing a
--- document is no moment to wait on wifi. Failures are logged rather than shown,
--- and the book stays flagged so the next run picks it up.
function Obsidian.exportOnClose(book)
    if not book then return end
    if not (Obsidian.getVaultPath() and Obsidian.isAutoExportEnabled()) then return end
    local ok, err = pcall(function()
        local book_id = History.findBookId(book)
        if not book_id then return end
        local outcome, export_err = Obsidian.exportBook(book_id, { "file" })
        if not outcome then logger.warn("Lunote obsidian:", tostring(export_err)) end
    end)
    if not ok then logger.warn("Lunote obsidian:", tostring(err)) end
end

--- Flags every book, then writes. For when the vault moved, or the notes were
--- deleted, or the format changed under them.
function Obsidian.rewriteEverything()
    History.markAllForObsidian()
    Obsidian.runInteractive()
end

--- Writes with a progress message, yielding to the UI first so the reader never
--- appears frozen. `Sync` runs the same work as part of one combined push; this
--- is the vault on its own.
function Obsidian.runInteractive()
    if not Obsidian.isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Connect to Obsidian, or set a vault folder, first."), timeout = 5 })
        return
    end
    if Obsidian.countPending() == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Your vault is already up to date."), timeout = 3 })
        return
    end

    local message = InfoMessage:new{ text = _("Writing to your Obsidian vault…") }
    UIManager:show(message)
    UIManager:forceRePaint()

    UIManager:nextTick(function()
        local written, err = Obsidian.exportPending(function(count)
            logger.dbg("Lunote obsidian: wrote", count)
        end)
        UIManager:close(message)
        if err then
            UIManager:show(InfoMessage:new{
                text = _("Export stopped:") .. "\n\n" .. tostring(err)
                    .. "\n\n" .. _("Written so far: ") .. tostring(written)
                    .. "\n" .. _("The rest will be retried next time."),
                timeout = 10,
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Wrote ") .. tostring(written) .. _(" note(s) to your vault."),
                timeout = 3,
            })
        end
    end)
end

return Obsidian
