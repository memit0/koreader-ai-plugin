--[[--
Writes one Obsidian note per book: every highlight from that book, the note you
wrote on it and the explanations Lunote generated, in reading order, into a
folder inside your vault.

An Obsidian vault is a folder of markdown files, so "syncing" here is writing
files — nothing to install on the Obsidian side, nothing to reach over wifi. The
vault can be a folder on the e-reader itself, or one your desktop keeps in step
with it (Syncthing, Dropbox, a USB copy); the plugin only ever sees a path.

Three rules shape this file:

1. **Nothing raises.** A vault on an SD card that is no longer there has to fail
   as a message, not as a dead reader.
2. **The note is generated, never merged into.** A book's note is rewritten whole
   from the store, so it always says exactly what the device holds. Your own
   writing belongs in your own notes, which can link to the block ids below.
3. **Nothing loads a whole book.** Highlights are read a page at a time and
   written straight out, so a book with a thousand highlights costs no more
   memory than one with ten.
]]
local History = require("lunote_history")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Env = require("lunote_env")

local CONFIGURATION = Env.loadOptional("lunote_config")

local Obsidian = {}

local PAGE_SIZE = 25
local DEFAULT_FOLDER = "Lunote"
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

local function trimPath(path)
    if type(path) ~= "string" then return nil end
    path = path:gsub("^%s+", ""):gsub("%s+$", "")
    -- A trailing slash would double up when joined, and "/" itself is not a vault
    path = path:gsub("/+$", "")
    if path == "" then return nil end
    return path
end

--- The vault root, or nil when the plugin has not been pointed at one.
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

function Obsidian.isConfigured()
    return Obsidian.getVaultPath() ~= nil
end

--- Points the plugin at a vault. Creating the notes folder now rather than at
--- the first export is what turns a typo into an error message while the user is
--- still looking at the dialog.
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

function Obsidian.isAutoExportEnabled()
    local stored = History.getState("obsidian_auto")
    if stored == "0" then return false end
    if stored == "1" then return true end
    -- Unset: exporting when a book closes is the point of the feature, so it is
    -- on as soon as a vault is configured.
    return feature("obsidian_auto_export") ~= false
end

function Obsidian.setAutoExport(enabled)
    History.setState("obsidian_auto", enabled and "1" or "0")
    return enabled
end

function Obsidian.countPending()
    return History.countObsidianPending() or 0
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

--- Where this book's note goes, relative to the vault root. A book keeps the
--- path it was first written to, so renaming a book in KOReader does not scatter
--- second copies through the vault; only a change of folder moves it.
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

-- Writing --------------------------------------------------------------------

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

--- Writes one book's note. Returns "written", "unchanged" or "empty", or nil
--- plus a message. `force` rewrites a book whose note is already up to date.
function Obsidian.exportBook(book_id, force)
    local vault = Obsidian.getVaultPath()
    if not vault then return nil, "No Obsidian vault folder is set." end

    local ok, result, err = pcall(function()
        local book = History.getObsidianBook(book_id)
        if not book then return nil, "That book is not in the store." end
        if book.n_items == 0 and book.n_conversations == 0 then
            -- Every book you open gets a row; only the ones you highlighted in
            -- earn a note. Clear the flag so it stops being counted as pending.
            History.markObsidianWritten(book_id)
            return "empty"
        end
        if not force and not book.obsidian_dirty then return "unchanged" end

        local relative = relativePathFor(book)
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

        -- Rename cannot overwrite on every filesystem an e-reader might use, so
        -- the old note has to move out of the way first. It is kept until the new
        -- one is in place: this is someone's vault, and a failed rename must not
        -- be how they find out their note is gone.
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

        History.setObsidianPath(book_id, relative)
        History.markObsidianWritten(book_id)
        return "written"
    end)

    if not ok then
        logger.warn("Lunote obsidian:", tostring(result))
        return nil, tostring(result)
    end
    if not result then return nil, err end
    return result
end

--- Writes every book whose note is out of date. `progress(n)` may return false to
--- stop at the next book. Returns the number written, plus a message if it
--- stopped early. Books that fail stay flagged and are retried next time.
function Obsidian.exportPending(progress)
    if not Obsidian.isConfigured() then return 0, "No Obsidian vault folder is set." end

    local cursor, written = 0, 0
    while true do
        local page = History.getObsidianPendingBooks(cursor, PAGE_SIZE)
        if not page or #page.ids == 0 then return written end

        for _index, book_id in ipairs(page.ids) do
            local outcome, err = Obsidian.exportBook(book_id)
            if not outcome then return written, err end
            if outcome == "written" then written = written + 1 end
            if progress and progress(written) == false then return written, "cancelled" end
        end

        cursor = page.cursor
        if #page.ids < PAGE_SIZE then return written end
    end
end

--- Writes the note for the book just closed, if that is switched on. Failures are
--- logged rather than shown: the reader is on its way out of the document, and
--- the book stays flagged so the next export picks it up.
function Obsidian.exportOnClose(book)
    if not book then return end
    if not (Obsidian.isConfigured() and Obsidian.isAutoExportEnabled()) then return end
    local ok, err = pcall(function()
        local book_id = History.findBookId(book)
        if not book_id then return end
        local outcome, export_err = Obsidian.exportBook(book_id)
        if not outcome then logger.warn("Lunote obsidian:", tostring(export_err)) end
    end)
    if not ok then logger.warn("Lunote obsidian:", tostring(err)) end
end

--- Flags every book, then exports. For when the vault moved, or the notes were
--- deleted, or the format changed under them.
function Obsidian.rewriteEverything()
    History.markAllForObsidian()
    Obsidian.runInteractive()
end

--- An export with a progress message, yielding to the UI first so the reader
--- never appears frozen while the vault is being written.
function Obsidian.runInteractive()
    if not Obsidian.isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Set your Obsidian vault folder first."), timeout = 5 })
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
