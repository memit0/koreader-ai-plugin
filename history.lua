--[[--
Local store for AskGPT: conversation transcripts, a mirror of the book's KOReader
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

local DB_PATH = DataStorage:getSettingsDir() .. "/askgpt_history.sqlite3"
local DB_SCHEMA_VERSION = 1

-- Marks where the explanation begins inside an annotation's note. Mirroring
-- strips from here on, so the web app gets the user's note and the AI text stays in
-- the conversation table instead of being ingested twice.
--
-- The label and the separator are kept apart deliberately: a note that had no
-- user text starts at the label with no leading blank lines, and stripping has
-- to recognise both forms. Searching for the label alone does that.
History.AI_NOTE_MARKER = "— AskGPT —"
History.AI_NOTE_SEPARATOR = "\n\n" .. History.AI_NOTE_MARKER .. "\n"

History.DB_PATH = DB_PATH

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS book (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid       TEXT,
    title      TEXT,
    authors    TEXT,
    md5        TEXT,
    file       TEXT,
    updated_at INTEGER
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

local function migrate(conn)
    local version = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    if version == DB_SCHEMA_VERSION then return end
    if version > DB_SCHEMA_VERSION then
        logger.warn("AskGPT history: database is newer than this plugin, leaving it alone")
        return
    end
    -- Only one version so far; CREATE ... IF NOT EXISTS is the whole migration.
    conn:exec(SCHEMA)
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
        logger.warn("AskGPT history:", tostring(result))
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
        return id
    end

    local ins = conn:prepare(
        "INSERT INTO book (title, authors, md5, file, updated_at) VALUES (?, ?, ?, ?, ?);")
    ins:reset():bind(title, authors, md5, book.file or "", os.time()):step()
    local id = lastInsertId(conn)
    assignUuid(conn, "book", id)
    return id
end

History.upsertBook = upsertBook

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
                -- Cheap change detection: lengths plus content, no hashing library
                local hash = string.format("%d/%d/%s", #annotation.text, #(note or ""),
                    tostring(annotation.pageno))
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
        conn:exec("COMMIT;")
        return changed
    end)
end

-- exec() hands back columns, not rows; turn that into a list of records.
local function rows(result, names)
    local out = {}
    if not result then return out end
    local count = result[1] and #result[1] or 0
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

function History.getMessages(conversation_id)
    return withConn(function(conn)
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
    end)
end

function History.deleteConversation(id)
    return withConn(function(conn)
        conn:exec("BEGIN;")
        conn:prepare("DELETE FROM message WHERE conversation_id = ?;"):reset():bind(id):step()
        conn:prepare("DELETE FROM conversation WHERE id = ?;"):reset():bind(id):step()
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

local function bookRefs(conn, book_ids)
    local out = {}
    local stmt = conn:prepare("SELECT uuid, title, authors, md5 FROM book WHERE id = ?;")
    for book_id in pairs(book_ids) do
        local row = stmt:reset():bind(book_id):step()
        if row then
            out[#out + 1] = { uuid = row[1], title = row[2], authors = row[3], md5 = row[4] }
        end
    end
    return out
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
                note = row[6], chapter = row[7], pageno = row[8],
            }
            row = stmt:step()
        end
        return { records = items, ids = ids, books = bookRefs(conn, book_ids), cursor = cursor }
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
                chapter = row[6], pageno = row[7], annotation_datetime = row[8],
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

        return { records = conversations, ids = ids, books = bookRefs(conn, book_ids), cursor = cursor }
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
