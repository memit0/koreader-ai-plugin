--[[--
Local store for Lunote: conversation transcripts, a mirror of the book's KOReader
annotations, and the outbox flags the sync uses.

Two rules hold everywhere in here:

1. Nothing raises. A failing query returns nil and logs; the caller still shows the
   explanation. An uncaught error would take KOReader down with it.
2. Nothing loads the whole table. Reads are bounded by LIMIT and keyset cursors so
   memory stays flat however long your history gets.
]]
local DataStorage = require("datastorage")
local Device = require("device")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local History = {}

local DB_PATH = DataStorage:getSettingsDir() .. "/lunote_history.sqlite3"
local DB_SCHEMA_VERSION = 4

-- Marks where the explanation begins inside an annotation's note. Mirroring
-- strips from here on, so the web app gets the user's note and the AI text stays in
-- the conversation table instead of being ingested twice.
--
-- The label and the separator are kept apart deliberately: a note that had no
-- user text starts at the label with no leading blank lines, and stripping has
-- to recognise both forms. Searching for the label alone does that.
History.AI_NOTE_MARKER = "— Lunote —"
History.AI_NOTE_SEPARATOR = "\n\n" .. History.AI_NOTE_MARKER .. "\n"

History.DB_PATH = DB_PATH

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS book (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid                TEXT,
    title               TEXT,
    authors             TEXT,
    md5                 TEXT,
    file                TEXT,
    cover_png           BLOB,
    cover_sent          INTEGER NOT NULL DEFAULT 0,
    obsidian_dirty        INTEGER NOT NULL DEFAULT 1,
    obsidian_remote_dirty INTEGER NOT NULL DEFAULT 1,
    obsidian_path         TEXT,
    obsidian_written_at   INTEGER,
    obsidian_remote_at    INTEGER,
    updated_at            INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS book_identity ON book(title, authors, md5);

CREATE TABLE IF NOT EXISTS item (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid      TEXT,
    book_id   INTEGER NOT NULL,
    datetime  TEXT,
    text      TEXT,
    note      TEXT,
    chapter   TEXT,
    pageno    INTEGER,
    hash      TEXT,
    dirty     INTEGER NOT NULL DEFAULT 1,
    synced_at INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS item_book_datetime ON item(book_id, datetime);
CREATE INDEX IF NOT EXISTS item_dirty ON item(dirty, id);

CREATE TABLE IF NOT EXISTS conversation (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid                TEXT,
    book_id             INTEGER NOT NULL,
    kind                TEXT,
    highlight           TEXT,
    chapter             TEXT,
    pageno              INTEGER,
    annotation_datetime TEXT,
    model               TEXT,
    created_at          INTEGER,
    updated_at          INTEGER,
    dirty               INTEGER NOT NULL DEFAULT 1,
    synced_at           INTEGER
);
CREATE INDEX IF NOT EXISTS conversation_book ON conversation(book_id, created_at);
CREATE INDEX IF NOT EXISTS conversation_dirty ON conversation(dirty, id);

CREATE TABLE IF NOT EXISTS message (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL,
    ordinal         INTEGER,
    role            TEXT,
    content         TEXT,
    created_at      INTEGER
);
CREATE INDEX IF NOT EXISTS message_conversation ON message(conversation_id, ordinal);

CREATE TABLE IF NOT EXISTS sync_state (
    key   TEXT PRIMARY KEY,
    value TEXT
);
]]

--- Removes the appended explanation, leaving only what the user wrote. Returns
--- nil when the note was nothing but an explanation.
function History.stripAiNote(note)
    if not note then return nil end
    local at = note:find(History.AI_NOTE_MARKER, 1, true)
    if not at then return note end
    local user_part = note:sub(1, at - 1):gsub("%s+$", "")
    if user_part == "" then return nil end
    return user_part
end

local function randomHex(bytes)
    local file = io.open("/dev/urandom", "rb")
    if file then
        local raw = file:read(bytes)
        file:close()
        if raw and #raw == bytes then
            return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
        end
    end
    -- No urandom (or a short read): good enough for an id that is only ever
    -- combined with a per-device rowid.
    math.randomseed(os.time())
    local out = {}
    for i = 1, bytes do out[i] = string.format("%02x", math.random(0, 255)) end
    return table.concat(out)
end

local function getStateIn(conn, key)
    local stmt = conn:prepare("SELECT value FROM sync_state WHERE key = ?;")
    local row = stmt:reset():bind(key):step()
    return row and row[1] or nil
end

local function setStateIn(conn, key, value)
    local stmt = conn:prepare("INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?);")
    stmt:reset():bind(key, tostring(value)):step()
end

-- CREATE ... IF NOT EXISTS only helps for tables that don't exist yet; a column
-- added to an existing table needs its own ALTER, guarded by a version check
-- since SQLite has no "ADD COLUMN IF NOT EXISTS".
local function migrate(conn)
    local version = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    if version == DB_SCHEMA_VERSION then return end
    if version > DB_SCHEMA_VERSION then
        logger.warn("Lunote history: database is newer than this plugin, leaving it alone")
        return
    end

    conn:exec(SCHEMA)

    -- version 0 means CREATE TABLE just ran above and already has these columns;
    -- only a pre-existing `book` table is missing them.
    if version == 1 then
        conn:exec("ALTER TABLE book ADD COLUMN cover_png BLOB;")
        conn:exec("ALTER TABLE book ADD COLUMN cover_sent INTEGER NOT NULL DEFAULT 0;")
    end
    if version >= 1 and version <= 2 then
        -- Defaulting to 1 is what makes the first vault export pick up every
        -- book already in the store, not just the ones touched since.
        conn:exec("ALTER TABLE book ADD COLUMN obsidian_dirty INTEGER NOT NULL DEFAULT 1;")
        conn:exec("ALTER TABLE book ADD COLUMN obsidian_path TEXT;")
        conn:exec("ALTER TABLE book ADD COLUMN obsidian_written_at INTEGER;")
    end
    if version >= 1 and version <= 3 then
        -- A note written to a folder on the device says nothing about whether
        -- Obsidian itself has it, so the two destinations count separately.
        conn:exec("ALTER TABLE book ADD COLUMN obsidian_remote_dirty INTEGER NOT NULL DEFAULT 1;")
        conn:exec("ALTER TABLE book ADD COLUMN obsidian_remote_at INTEGER;")
    end

    conn:exec(string.format("PRAGMA user_version=%d;", DB_SCHEMA_VERSION))
end

local function openDB()
    local conn = SQ3.open(DB_PATH)
    -- WAL is a big win but is not safe on every filesystem an e-reader might use
    if Device:canUseWAL() then
        conn:exec("PRAGMA journal_mode=WAL;")
    else
        conn:exec("PRAGMA journal_mode=TRUNCATE;")
    end
    migrate(conn)
    if not getStateIn(conn, "device_uuid") then
        setStateIn(conn, "device_uuid", randomHex(8))
    end
    return conn
end

-- Runs body with a connection, always closing it. Returns nil plus the error
-- instead of raising, so no caller can bring the reader down.
local function withConn(body)
    local conn
    local ok, result = pcall(function()
        conn = openDB()
        return body(conn)
    end)
    if conn then pcall(function() conn:close() end) end
    if not ok then
        logger.warn("Lunote history:", tostring(result))
        return nil, tostring(result)
    end
    return result
end

History.withConn = withConn

local function lastInsertId(conn)
    return tonumber(conn:rowexec("SELECT last_insert_rowid();"))
end

-- uuid = <device>:<table>:<rowid>. Unique across devices without needing an RNG
-- per record, and stable, so re-pushing a record is an upsert not a duplicate.
local function assignUuid(conn, tbl, id)
    local device_uuid = getStateIn(conn, "device_uuid")
    local uuid = string.format("%s:%s:%d", device_uuid, tbl, id)
    local stmt = conn:prepare("UPDATE " .. tbl .. " SET uuid = ? WHERE id = ?;")
    stmt:reset():bind(uuid, id):step()
    return uuid
end

-- Where a book's note can go. Each destination keeps its own outbox flag: a note
-- written to a folder on the device says nothing about whether Obsidian itself
-- has it, and neither may consume what the other still owes. The web app's own
-- `dirty` columns are a third, equally independent, outbox.
--
-- Column names are only ever looked up in this table, never built from a caller's
-- string.
local OBSIDIAN_DESTINATIONS = {
    file   = { dirty = "obsidian_dirty",        at = "obsidian_written_at" },
    remote = { dirty = "obsidian_remote_dirty", at = "obsidian_remote_at" },
}

local function destinationColumns(destination)
    return OBSIDIAN_DESTINATIONS[destination] or OBSIDIAN_DESTINATIONS.file
end

--- Flags a book as needing its note rewritten, everywhere it is sent.
local function markBookForObsidian(conn, book_id)
    if not book_id then return end
    conn:prepare("UPDATE book SET obsidian_dirty = 1, obsidian_remote_dirty = 1 WHERE id = ?;")
        :reset():bind(book_id):step()
end

local function upsertBook(conn, book)
    local title = book.title or ""
    local authors = book.authors or ""
    local md5 = book.md5 or ""

    local stmt = conn:prepare("SELECT id FROM book WHERE title = ? AND authors = ? AND md5 = ?;")
    local row = stmt:reset():bind(title, authors, md5):step()
    if row then
        local id = tonumber(row[1])
        local upd = conn:prepare("UPDATE book SET file = ?, updated_at = ? WHERE id = ?;")
        upd:reset():bind(book.file or "", os.time(), id):step()
        -- Only a freshly extracted cover writes here; never clobber one already
        -- cached (or already sent) with a nil.
        if book.cover_png then
            conn:prepare("UPDATE book SET cover_png = ?, cover_sent = 0 WHERE id = ?;")
                :reset():bind(book.cover_png, id):step()
        end
        return id
    end

    local ins = conn:prepare(
        "INSERT INTO book (title, authors, md5, file, cover_png, updated_at) VALUES (?, ?, ?, ?, ?, ?);")
    ins:reset():bind(title, authors, md5, book.file or "", book.cover_png, os.time()):step()
    local id = lastInsertId(conn)
    assignUuid(conn, "book", id)
    return id
end

History.upsertBook = upsertBook

--- Whether `book` (identified the same way upsertBook matches it) still needs its
--- cover extracted: no row yet, or a row with no cover cached and none sent yet.
function History.needsCoverExtraction(book)
    return withConn(function(conn)
        local stmt = conn:prepare([[
            SELECT cover_png, cover_sent FROM book WHERE title = ? AND authors = ? AND md5 = ?;
        ]])
        local row = stmt:reset():bind(book.title or "", book.authors or "", book.md5 or ""):step()
        if not row then return true end
        return row[1] == nil and tonumber(row[2]) == 0
    end)
end

--- Marks each book's cover delivered: the local copy is no longer needed.
function History.markCoverSent(book_ids)
    if not book_ids or #book_ids == 0 then return true end
    return withConn(function(conn)
        conn:exec("BEGIN;")
        local stmt = conn:prepare("UPDATE book SET cover_sent = 1, cover_png = NULL WHERE id = ?;")
        for _, id in ipairs(book_ids) do
            stmt:reset():bind(id):step()
        end
        conn:exec("COMMIT;")
        return true
    end)
end

--- Records a new conversation plus its opening messages. Returns the conversation id.
function History.startConversation(info)
    return withConn(function(conn)
        conn:exec("BEGIN;")
        local book_id = upsertBook(conn, info.book)
        local now = os.time()
        local stmt = conn:prepare([[
            INSERT INTO conversation
                (book_id, kind, highlight, chapter, pageno, annotation_datetime,
                 model, created_at, updated_at, dirty)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1);
        ]])
        stmt:reset():bind(book_id, info.kind or "explain", info.highlight or "",
            info.chapter, info.pageno, info.annotation_datetime, info.model,
            now, now):step()
        local id = lastInsertId(conn)
        assignUuid(conn, "conversation", id)

        local ins = conn:prepare(
            "INSERT INTO message (conversation_id, ordinal, role, content, created_at) VALUES (?, ?, ?, ?, ?);")
        for i, message in ipairs(info.messages or {}) do
            ins:reset():bind(id, i, message.role, message.content, now):step()
        end
        markBookForObsidian(conn, book_id)
        conn:exec("COMMIT;")
        return id
    end)
end

--- Appends messages to an existing conversation and re-marks it for sync.
function History.appendMessages(conversation_id, messages)
    if not conversation_id then return end
    return withConn(function(conn)
        conn:exec("BEGIN;")
        local row = conn:prepare("SELECT COALESCE(MAX(ordinal), 0) FROM message WHERE conversation_id = ?;")
            :reset():bind(conversation_id):step()
        local ordinal = tonumber(row and row[1] or 0)
        local now = os.time()
        local ins = conn:prepare(
            "INSERT INTO message (conversation_id, ordinal, role, content, created_at) VALUES (?, ?, ?, ?, ?);")
        for _, message in ipairs(messages) do
            ordinal = ordinal + 1
            ins:reset():bind(conversation_id, ordinal, message.role, message.content, now):step()
        end
        conn:prepare("UPDATE conversation SET dirty = 1, updated_at = ? WHERE id = ?;")
            :reset():bind(now, conversation_id):step()
        local owner = conn:prepare("SELECT book_id FROM conversation WHERE id = ?;")
            :reset():bind(conversation_id):step()
        markBookForObsidian(conn, owner and tonumber(owner[1]))
        conn:exec("COMMIT;")
        return ordinal
    end)
end

--- Mirrors a book's KOReader annotations into the local store, marking only the
--- rows whose content actually changed. Called when a document closes, so sync
--- never has to walk the filesystem.
function History.mirrorAnnotations(book, annotations)
    return withConn(function(conn)
        conn:exec("BEGIN;")
        local book_id = upsertBook(conn, book)
        local changed = 0

        local select_stmt = conn:prepare("SELECT id, hash FROM item WHERE book_id = ? AND datetime = ?;")
        local insert_stmt = conn:prepare([[
            INSERT INTO item (book_id, datetime, text, note, chapter, pageno, hash, dirty)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1);
        ]])
        local update_stmt = conn:prepare([[
            UPDATE item SET text = ?, note = ?, chapter = ?, pageno = ?, hash = ?, dirty = 1
            WHERE id = ?;
        ]])

        for _, annotation in ipairs(annotations or {}) do
            -- Page-only bookmarks carry no highlighted text; nothing to mirror.
            if annotation.text and annotation.text ~= "" and annotation.datetime then
                local note = History.stripAiNote(annotation.note)
                local fields = {
                    annotation.text, note or "", annotation.chapter or "",
                    tostring(annotation.pageno or ""),
                }
                for i, value in ipairs(fields) do
                    fields[i] = #value .. ":" .. value
                end
                local hash = table.concat(fields, "|")
                local existing = select_stmt:reset():bind(book_id, annotation.datetime):step()
                if not existing then
                    insert_stmt:reset():bind(book_id, annotation.datetime, annotation.text,
                        note, annotation.chapter, annotation.pageno, hash):step()
                    assignUuid(conn, "item", lastInsertId(conn))
                    changed = changed + 1
                elseif existing[2] ~= hash then
                    update_stmt:reset():bind(annotation.text, note, annotation.chapter,
                        annotation.pageno, hash, tonumber(existing[1])):step()
                    changed = changed + 1
                end
            end
        end
        if changed > 0 then markBookForObsidian(conn, book_id) end
        conn:exec("COMMIT;")
        return changed
    end)
end

-- exec() hands back columns, not rows; turn that into a list of records.
local function rows(result, names)
    local out = {}
    if not result then return out end
    -- __rows is set by backends that can report it; a column containing NULLs
    -- would otherwise make # unreliable.
    local count = result.__rows or (result[1] and #result[1]) or 0
    for i = 1, count do
        local record = {}
        for column, name in ipairs(names) do
            record[name] = result[column][i]
        end
        out[#out + 1] = record
    end
    return out
end

History.rows = rows

function History.listBooks()
    return withConn(function(conn)
        local result = conn:exec([[
            SELECT b.id, b.title, b.authors,
                   (SELECT COUNT(*) FROM item i WHERE i.book_id = b.id),
                   (SELECT COUNT(*) FROM conversation c WHERE c.book_id = b.id),
                   b.updated_at
            FROM book b
            ORDER BY b.updated_at DESC;
        ]])
        return rows(result, { "id", "title", "authors", "n_items", "n_conversations", "updated_at" })
    end)
end

function History.listConversations(book_id)
    return withConn(function(conn)
        local stmt = conn:prepare([[
            SELECT id, kind, highlight, chapter, pageno, created_at
            FROM conversation WHERE book_id = ? ORDER BY created_at DESC;
        ]])
        local out = {}
        stmt:reset():bind(book_id)
        local row = stmt:step()
        while row do
            out[#out + 1] = {
                id = tonumber(row[1]), kind = row[2], highlight = row[3],
                chapter = row[4], pageno = row[5], created_at = tonumber(row[6]),
            }
            row = stmt:step()
        end
        return out
    end)
end

local function loadMessages(conn, conversation_id)
    local stmt = conn:prepare(
        "SELECT role, content FROM message WHERE conversation_id = ? ORDER BY ordinal;")
    local out = {}
    stmt:reset():bind(conversation_id)
    local row = stmt:step()
    while row do
        out[#out + 1] = { role = row[1], content = row[2] }
        row = stmt:step()
    end
    return out
end

function History.getMessages(conversation_id)
    return withConn(function(conn) return loadMessages(conn, conversation_id) end)
end

function History.deleteConversation(id)
    return withConn(function(conn)
        conn:exec("BEGIN;")
        -- Read the owner before the row goes: its vault note has to be rewritten
        -- without this explanation in it.
        local owner = conn:prepare("SELECT book_id FROM conversation WHERE id = ?;")
            :reset():bind(id):step()
        conn:prepare("DELETE FROM message WHERE conversation_id = ?;"):reset():bind(id):step()
        conn:prepare("DELETE FROM conversation WHERE id = ?;"):reset():bind(id):step()
        markBookForObsidian(conn, owner and tonumber(owner[1]))
        conn:exec("COMMIT;")
        return true
    end)
end

function History.countDirty()
    return withConn(function(conn)
        local items = tonumber(conn:rowexec("SELECT COUNT(*) FROM item WHERE dirty = 1;")) or 0
        local convs = tonumber(conn:rowexec("SELECT COUNT(*) FROM conversation WHERE dirty = 1;")) or 0
        return items + convs
    end)
end

function History.hasPendingCovers()
    return withConn(function(conn)
        return (tonumber(conn:rowexec([[
            SELECT COUNT(*) FROM book WHERE cover_png IS NOT NULL AND cover_sent = 0;
        ]])) or 0) > 0
    end)
end

function History.getState(key)
    return withConn(function(conn) return getStateIn(conn, key) end)
end

function History.setState(key, value)
    return withConn(function(conn) setStateIn(conn, key, value) return true end)
end

--- Drops synced conversations older than a cut-off, for anyone watching storage.
function History.prune(before_timestamp)
    return withConn(function(conn)
        conn:exec("BEGIN;")
        conn:prepare([[
            DELETE FROM message WHERE conversation_id IN
                (SELECT id FROM conversation WHERE dirty = 0 AND created_at < ?);
        ]]):reset():bind(before_timestamp):step()
        conn:prepare("DELETE FROM conversation WHERE dirty = 0 AND created_at < ?;")
            :reset():bind(before_timestamp):step()
        conn:exec("COMMIT;")
        return true
    end)
end

function History.deleteDatabase()
    return os.remove(DB_PATH)
end

-- Outbox ------------------------------------------------------------------
-- Everything below is keyset paginated (`id > cursor`) rather than using OFFSET,
-- so a batch costs the same whether it is the first or the thousandth.

-- Returns the book refs to send alongside a batch, plus the ids among them whose
-- (still-local) cover just got attached — the caller marks those sent once the
-- server has acknowledged the batch, mirroring how item/conversation dirty flags
-- are only cleared after a successful post.
local function bookRefs(conn, book_ids)
    local refs, cover_ids = {}, {}
    local stmt = conn:prepare(
        "SELECT uuid, title, authors, md5, cover_png, cover_sent FROM book WHERE id = ?;")
    for book_id in pairs(book_ids) do
        local row = stmt:reset():bind(book_id):step()
        if row then
            local ref = { uuid = row[1], title = row[2], authors = row[3], md5 = row[4] }
            if row[5] and tonumber(row[6]) == 0 then
                ref.cover_base64 = require("mime").b64(row[5])
                cover_ids[#cover_ids + 1] = book_id
            end
            refs[#refs + 1] = ref
        end
    end
    return refs, cover_ids
end

--- One page of covers which are not already riding with dirty records.
function History.getPendingCovers(after_id, limit)
    return withConn(function(conn)
        local stmt = conn:prepare([[
            SELECT id, uuid, title, authors, md5, cover_png
            FROM book
            WHERE cover_png IS NOT NULL AND cover_sent = 0 AND id > ?
            ORDER BY id LIMIT ?;
        ]])
        local books, ids, cursor = {}, {}, after_id or 0
        stmt:reset():bind(after_id or 0, limit or 25)
        local row = stmt:step()
        while row do
            local id = tonumber(row[1])
            ids[#ids + 1] = id
            cursor = id
            books[#books + 1] = {
                uuid = row[2], title = row[3], authors = row[4], md5 = row[5],
                cover_base64 = require("mime").b64(row[6]),
            }
            row = stmt:step()
        end
        return { books = books, ids = ids, cursor = cursor }
    end)
end

--- One page of unsynced annotations. Returns the records, the books they belong
--- to, and the cursor to resume from.
function History.getDirtyItems(after_id, limit)
    return withConn(function(conn)
        -- book_uuid, not the local rowid: the server has no idea what our rowids mean
        local stmt = conn:prepare([[
            SELECT i.id, i.uuid, i.book_id, i.datetime, i.text, i.note, i.chapter, i.pageno,
                   b.uuid
            FROM item i JOIN book b ON b.id = i.book_id
            WHERE i.dirty = 1 AND i.id > ? ORDER BY i.id LIMIT ?;
        ]])
        local items, ids, book_ids, cursor = {}, {}, {}, after_id or 0
        stmt:reset():bind(after_id or 0, limit or 25)
        local row = stmt:step()
        while row do
            local id = tonumber(row[1])
            book_ids[tonumber(row[3])] = true
            ids[#ids + 1] = id
            cursor = id
            items[#items + 1] = {
                uuid = row[2], book_uuid = row[9], datetime = row[4], text = row[5],
                note = row[6], chapter = row[7], pageno = tonumber(row[8]),
            }
            row = stmt:step()
        end
        local books, cover_ids = bookRefs(conn, book_ids)
        return { records = items, ids = ids, books = books, cover_ids = cover_ids, cursor = cursor }
    end)
end

--- One page of unsynced conversations, each with its full message thread.
function History.getDirtyConversations(after_id, limit)
    return withConn(function(conn)
        local stmt = conn:prepare([[
            SELECT c.id, c.uuid, c.book_id, c.kind, c.highlight, c.chapter, c.pageno,
                   c.annotation_datetime, c.model, c.created_at, b.uuid
            FROM conversation c JOIN book b ON b.id = c.book_id
            WHERE c.dirty = 1 AND c.id > ? ORDER BY c.id LIMIT ?;
        ]])
        local message_stmt = conn:prepare(
            "SELECT ordinal, role, content FROM message WHERE conversation_id = ? ORDER BY ordinal;")

        local conversations, ids, book_ids, cursor = {}, {}, {}, after_id or 0
        stmt:reset():bind(after_id or 0, limit or 25)
        local row = stmt:step()
        while row do
            local id = tonumber(row[1])
            book_ids[tonumber(row[3])] = true
            ids[#ids + 1] = id
            cursor = id
            conversations[#conversations + 1] = {
                uuid = row[2], book_uuid = row[11], kind = row[4], highlight = row[5],
                chapter = row[6], pageno = tonumber(row[7]), annotation_datetime = row[8],
                model = row[9], created_at = tonumber(row[10]), messages = {},
            }
            row = stmt:step()
        end

        -- Bounded by `limit`, so this stays a handful of small queries
        for index, conversation in ipairs(conversations) do
            message_stmt:reset():bind(ids[index])
            local message_row = message_stmt:step()
            while message_row do
                conversation.messages[#conversation.messages + 1] = {
                    ordinal = tonumber(message_row[1]), role = message_row[2], content = message_row[3],
                }
                message_row = message_stmt:step()
            end
        end

        local books, cover_ids = bookRefs(conn, book_ids)
        return { records = conversations, ids = ids, books = books, cover_ids = cover_ids, cursor = cursor }
    end)
end

-- Obsidian export ---------------------------------------------------------
-- Reads for the vault writer. A book's note is regenerated whole, so these
-- queries are paginated the same way the outbox is: the note for a book with a
-- thousand highlights costs the same memory as the note for one with ten.

-- A book only earns a note once it holds something worth writing. Every book you
-- open gets a row here — mirroring runs on close whether or not you highlighted
-- anything — and an empty note per book you have merely opened would be noise in
-- someone's vault.
local HAS_CONTENT = [[
    (EXISTS (SELECT 1 FROM item i WHERE i.book_id = b.id)
     OR EXISTS (SELECT 1 FROM conversation c WHERE c.book_id = b.id))
]]

--- How many books are out of date at `destination`, or at either of them when
--- that is "any" — which is what the menu counts when a vault folder and an
--- Obsidian address are both configured.
function History.countObsidianPending(destination)
    local condition
    if destination == "any" then
        condition = "(b.obsidian_dirty = 1 OR b.obsidian_remote_dirty = 1)"
    else
        condition = "b." .. destinationColumns(destination).dirty .. " = 1"
    end
    return withConn(function(conn)
        return tonumber(conn:rowexec("SELECT COUNT(*) FROM book b WHERE " .. condition
            .. " AND " .. HAS_CONTENT .. ";")) or 0
    end)
end

--- One page of books whose note is out of date at `destination`.
function History.getObsidianPendingBooks(destination, after_id, limit)
    local columns = destinationColumns(destination)
    return withConn(function(conn)
        local stmt = conn:prepare([[
            SELECT b.id FROM book b
            WHERE b.]] .. columns.dirty .. [[ = 1 AND b.id > ? AND ]] .. HAS_CONTENT .. [[
            ORDER BY b.id LIMIT ?;
        ]])
        local ids, cursor = {}, after_id or 0
        stmt:reset():bind(after_id or 0, limit or 25)
        local row = stmt:step()
        while row do
            cursor = tonumber(row[1])
            ids[#ids + 1] = cursor
            row = stmt:step()
        end
        return { ids = ids, cursor = cursor }
    end)
end

--- Everything the vault writer needs about a book except its highlights.
function History.getObsidianBook(book_id)
    return withConn(function(conn)
        local row = conn:prepare([[
            SELECT b.uuid, b.title, b.authors, b.md5, b.file, b.obsidian_path, b.obsidian_dirty,
                   (SELECT COUNT(*) FROM item i WHERE i.book_id = b.id),
                   (SELECT COUNT(*) FROM conversation c WHERE c.book_id = b.id),
                   b.obsidian_remote_dirty
            FROM book b WHERE b.id = ?;
        ]]):reset():bind(book_id):step()
        if not row then return nil end
        return {
            id = book_id, uuid = row[1], title = row[2], authors = row[3], md5 = row[4],
            file = row[5], obsidian_path = row[6],
            n_items = tonumber(row[8]) or 0, n_conversations = tonumber(row[9]) or 0,
            pending = { file = tonumber(row[7]) == 1, remote = tonumber(row[10]) == 1 },
        }
    end)
end

--- The local id for a book identified the way upsertBook matches it, or nil.
function History.findBookId(book)
    return withConn(function(conn)
        local row = conn:prepare("SELECT id FROM book WHERE title = ? AND authors = ? AND md5 = ?;")
            :reset():bind(book.title or "", book.authors or "", book.md5 or ""):step()
        return row and tonumber(row[1]) or nil
    end)
end

--- One page of a book's highlights in reading order. `cursor` is the last record
--- of the previous page (nil to start). Ordering by page rather than by rowid is
--- what keeps a highlight added on a re-read from landing at the end of the note,
--- so the keyset is the whole sort key rather than just the id.
function History.getObsidianItems(book_id, cursor, limit)
    return withConn(function(conn)
        local stmt = conn:prepare([[
            SELECT id, uuid, datetime, text, note, chapter, pageno
            FROM item
            WHERE book_id = ?
              AND (COALESCE(pageno, 0) > ?
                OR (COALESCE(pageno, 0) = ? AND (COALESCE(datetime, '') > ?
                OR (COALESCE(datetime, '') = ? AND id > ?))))
            ORDER BY COALESCE(pageno, 0), COALESCE(datetime, ''), id
            LIMIT ?;
        ]])
        local pageno = cursor and cursor.pageno or 0
        local datetime = cursor and cursor.datetime or ""
        local id = cursor and cursor.id or 0
        stmt:reset():bind(book_id, pageno, pageno, datetime, datetime, id, limit or 25)

        local records, last = {}, nil
        local row = stmt:step()
        while row do
            last = {
                id = tonumber(row[1]), pageno = tonumber(row[7]) or 0, datetime = row[3] or "",
            }
            records[#records + 1] = {
                id = last.id, uuid = row[2], datetime = row[3], text = row[4], note = row[5],
                chapter = row[6], pageno = tonumber(row[7]),
            }
            row = stmt:step()
        end
        return { records = records, cursor = last or cursor }
    end)
end

--- The explanations attached to one highlight, oldest first, with their messages.
function History.getConversationsForAnnotation(book_id, datetime)
    return withConn(function(conn)
        local stmt = conn:prepare([[
            SELECT id, kind, model, created_at FROM conversation
            WHERE book_id = ? AND annotation_datetime = ? ORDER BY created_at, id;
        ]])
        local out = {}
        stmt:reset():bind(book_id, datetime)
        local row = stmt:step()
        while row do
            out[#out + 1] = { id = tonumber(row[1]), kind = row[2], model = row[3],
                created_at = tonumber(row[4]) }
            row = stmt:step()
        end
        for _, conversation in ipairs(out) do
            conversation.messages = loadMessages(conn, conversation.id)
        end
        return out
    end)
end

--- One page of explanations that have no highlight to sit under: the annotation
--- write failed (a scanned PDF can hand back a selection with no positions), or
--- the highlight has since been deleted. They would otherwise vanish from the
--- vault entirely.
function History.getUnanchoredConversations(book_id, after_id, limit)
    return withConn(function(conn)
        local stmt = conn:prepare([[
            SELECT c.id, c.kind, c.highlight, c.chapter, c.pageno, c.model, c.created_at
            FROM conversation c
            WHERE c.book_id = ? AND c.id > ?
              AND (c.annotation_datetime IS NULL OR c.annotation_datetime = ''
                   OR NOT EXISTS (SELECT 1 FROM item i
                                  WHERE i.book_id = c.book_id AND i.datetime = c.annotation_datetime))
            ORDER BY c.id LIMIT ?;
        ]])
        local records, cursor = {}, after_id or 0
        stmt:reset():bind(book_id, after_id or 0, limit or 25)
        local row = stmt:step()
        while row do
            cursor = tonumber(row[1])
            records[#records + 1] = {
                id = cursor, kind = row[2], highlight = row[3], chapter = row[4],
                pageno = tonumber(row[5]), model = row[6], created_at = tonumber(row[7]),
            }
            row = stmt:step()
        end
        for _, conversation in ipairs(records) do
            conversation.messages = loadMessages(conn, conversation.id)
        end
        return { records = records, cursor = cursor }
    end)
end

--- Whether another book has already claimed this path inside the vault.
function History.isObsidianPathTaken(path, book_id)
    return withConn(function(conn)
        local row = conn:prepare("SELECT COUNT(*) FROM book WHERE obsidian_path = ? AND id <> ?;")
            :reset():bind(path, book_id or 0):step()
        return (tonumber(row and row[1]) or 0) > 0
    end)
end

--- Remembers where a book's note lives, so later exports overwrite that same
--- file rather than leaving a second copy behind under a new name.
function History.setObsidianPath(book_id, path)
    return withConn(function(conn)
        conn:prepare("UPDATE book SET obsidian_path = ? WHERE id = ?;")
            :reset():bind(path, book_id):step()
        return true
    end)
end

--- Called only once the note has landed at `destination`, so a failed write or a
--- dropped connection is simply retried.
function History.markObsidianWritten(book_id, destination)
    local columns = destinationColumns(destination)
    return withConn(function(conn)
        conn:prepare("UPDATE book SET " .. columns.dirty .. " = 0, " .. columns.at
            .. " = ? WHERE id = ?;"):reset():bind(os.time(), book_id):step()
        return true
    end)
end

--- Flags every book at every destination: what "Rewrite every note" is, and what
--- makes pointing the plugin at a new vault populate it in full.
function History.markAllForObsidian()
    return withConn(function(conn)
        conn:exec("UPDATE book SET obsidian_dirty = 1, obsidian_remote_dirty = 1;")
        return true
    end)
end

--- Marks a batch synced. Only called after the server has acknowledged it, so a
--- failure anywhere leaves the rows dirty and the next sync simply retries them.
function History.markSynced(table_name, ids)
    if table_name ~= "item" and table_name ~= "conversation" then return end
    if not ids or #ids == 0 then return true end
    return withConn(function(conn)
        conn:exec("BEGIN;")
        local stmt = conn:prepare(
            "UPDATE " .. table_name .. " SET dirty = 0, synced_at = ? WHERE id = ?;")
        local now = os.time()
        for _, id in ipairs(ids) do
            stmt:reset():bind(now, id):step()
        end
        conn:exec("COMMIT;")
        return true
    end)
end

return History
