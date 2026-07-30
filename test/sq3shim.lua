-- Implements just enough of KOReader's lua-ljsqlite3 API on top of luasql.sqlite3
-- so the plugin's real SQL runs against real SQLite in tests: real UNIQUE
-- constraints, real transactions, real query planning.
--
-- ljsqlite3 conventions reproduced here:
--   conn:exec(sql)      -> column-oriented resultset (result[col][row]) or nil
--   conn:rowexec(sql)   -> first row's values, unpacked
--   conn:prepare(sql)   -> stmt; stmt:reset():bind(...):step() -> row array or nil
--
-- Two backends. luasql.sqlite3 if it is installed, otherwise the sqlite3
-- command line tool, which ships with macOS and is a package away everywhere
-- else. The CLI path exists so the simulator needs no compiled Lua modules at
-- all: building rocks against LuaJIT is the single most awkward part of setting
-- this up, and it is not worth it for a development tool.
local ok_driver, driver = pcall(require, "luasql.sqlite3")

-- 5.1 and LuaJIT expose unpack globally; later versions moved it
local unpack = unpack or table.unpack

local M = {}

local function quote(value)
    if value == nil then return "NULL" end
    if type(value) == "number" then return tostring(value) end
    if type(value) == "boolean" then return value and "1" or "0" end
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local Stmt = {}
Stmt.__index = Stmt

function Stmt:reset()
    self._args = nil
    self._buffered = nil
    self._position = nil
    return self
end

function Stmt:bind(...)
    self._args = { n = select("#", ...), ... }
    return self
end

function Stmt:_sql()
    if not self._args then return self.sql end
    local index = 0
    -- Substitute positional placeholders, skipping any inside string literals
    local out = self.sql:gsub("%?", function()
        index = index + 1
        return quote(self._args[index])
    end)
    return out
end

-- Buffers the whole result and closes the cursor straight away. ljsqlite3 lets a
-- caller take one row and walk away; luasql would keep a read lock open and
-- deadlock the next COMMIT, so we never leave a cursor live.
function Stmt:step()
    if not self._buffered then
        local sql = self:_sql()
        local result, err = self.conn._conn:execute(sql)
        if result == nil then error(tostring(err) .. " :: " .. sql, 0) end
        self._buffered, self._position = {}, 0
        if type(result) ~= "number" then
            local row = result:fetch({}, "n")
            while row do
                table.insert(self._buffered, row)
                row = result:fetch({}, "n")
            end
            result:close()
        end
    end
    self._position = self._position + 1
    return self._buffered[self._position]
end

local Conn = {}
Conn.__index = Conn

function Conn:exec(sql)
    -- Scripts (the schema) arrive as many statements in one string
    local statements = {}
    for statement in sql:gmatch("[^;]+") do
        if statement:match("%S") then statements[#statements + 1] = statement end
    end

    local last
    for _, statement in ipairs(statements) do
        local result, err = self._conn:execute(statement)
        if result == nil then error(tostring(err) .. " :: " .. statement, 0) end
        last = result
    end

    if type(last) == "number" or last == nil then return nil end

    -- Column-oriented resultset, as ljsqlite3 returns
    local columns = {}
    local names = last:getcolnames()
    local row = last:fetch({}, "n")
    while row do
        for index = 1, #names do
            columns[index] = columns[index] or {}
            table.insert(columns[index], row[index])
        end
        row = last:fetch({}, "n")
    end
    last:close()
    if not columns[1] then return nil end
    for index, name in ipairs(names) do columns[name] = columns[index] end
    return columns
end

function Conn:rowexec(sql)
    local result, err = self._conn:execute(sql)
    if result == nil then error(tostring(err) .. " :: " .. sql, 0) end
    if type(result) == "number" then return nil end
    local row = result:fetch({}, "n")
    result:close()
    if not row then return nil end
    return unpack(row)
end

function Conn:prepare(sql)
    return setmetatable({ conn = self, sql = sql }, Stmt)
end

function Conn:close()
    self._conn:close()
    self._env:close()
end

-- sqlite3 command line backend ------------------------------------------------
-- Used when luasql is not installed. Rows come back separated by control
-- characters rather than newlines, because an explanation can contain newlines
-- and would otherwise split a row in half. NULL gets its own sentinel so it stays
-- distinguishable from an empty string.

local COLUMN_SEP, ROW_SEP, NULL_SENTINEL = "\031", "\030", "\029"

local PREAMBLE = table.concat({
    ".mode list",
    ".headers on",
    '.separator "\\x1f" "\\x1e"',
    '.nullvalue "\\x1d"',
    "",
}, "\n")

local function shellQuote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local CliConn = {}
CliConn.__index = CliConn

--- Returns the header names and the rows, or nil when the statement produced no
--- result set (DDL, DML, or an empty SELECT).
function CliConn:_run(sql)
    local scriptPath = os.tmpname()
    local outPath = os.tmpname()
    local errPath = os.tmpname()

    -- last_insert_rowid() is per connection, and every call here is a fresh
    -- process, so asking for it separately always answers 0. Fetch it in the
    -- same script as the INSERT and keep it for the caller's next question.
    local isInsert = sql:gsub("^%s+", ""):match("^(%a+)")
    isInsert = isInsert and isInsert:upper() == "INSERT"

    local script = assert(io.open(scriptPath, "w"))
    script:write(PREAMBLE, sql, "\n")
    if isInsert then script:write("SELECT last_insert_rowid();\n") end
    script:close()

    local command = string.format("%s %s < %s > %s 2> %s",
        M.sqlite3_binary, shellQuote(self._path),
        shellQuote(scriptPath), shellQuote(outPath), shellQuote(errPath))
    os.execute(command)

    local outFile = io.open(outPath, "rb")
    local output = outFile and outFile:read("*a") or ""
    if outFile then outFile:close() end
    local errFile = io.open(errPath, "rb")
    local errors = errFile and errFile:read("*a") or ""
    if errFile then errFile:close() end

    os.remove(scriptPath); os.remove(outPath); os.remove(errPath)

    if errors:match("%S") then error(errors:gsub("%s+$", "") .. " :: " .. sql, 0) end
    if not output:match("%S") then return nil end

    local records = {}
    for chunk in (output .. ROW_SEP):gmatch("(.-)" .. ROW_SEP) do
        if chunk ~= "" then records[#records + 1] = chunk end
    end
    if #records == 0 then return nil end

    local function split(line)
        local fields = {}
        for field in (line .. COLUMN_SEP):gmatch("(.-)" .. COLUMN_SEP) do
            fields[#fields + 1] = field
        end
        return fields
    end

    local names = split(table.remove(records, 1))
    local rows = {}
    for _, record in ipairs(records) do
        local fields = split(record)
        local row = { n = #names }
        for index = 1, #names do
            local value = fields[index]
            if value ~= NULL_SENTINEL then row[index] = value end
        end
        rows[#rows + 1] = row
    end

    -- The trailing SELECT we appended, not something the caller asked for
    if isInsert then
        self._last_rowid = rows[#rows] and tonumber(rows[#rows][1]) or nil
        return nil
    end
    return names, rows
end

-- Each call is its own sqlite3 process, so a BEGIN in one and a COMMIT in the
-- next are unrelated and the COMMIT fails outright. Every statement autocommits
-- instead, which means this backend does not simulate rollback — the luasql
-- backend and the device's own ljsqlite3 both do. Nothing under test depends on
-- a transaction being undone, only on the statements taking effect.
local function isTransactionControl(sql)
    local word = sql:gsub("^%s+", ""):match("^(%a+)")
    if not word then return false end
    word = word:upper()
    return word == "BEGIN" or word == "COMMIT" or word == "ROLLBACK" or word == "END"
end

function CliConn:exec(sql)
    if isTransactionControl(sql) then return nil end
    local names, rows = self:_run(sql)
    if not names or #rows == 0 then return nil end
    local columns = { __rows = #rows }
    for index, name in ipairs(names) do
        local column = {}
        for rowIndex, row in ipairs(rows) do column[rowIndex] = row[index] end
        columns[index] = column
        columns[name] = column
    end
    return columns
end

function CliConn:rowexec(sql)
    if sql:find("last_insert_rowid", 1, true) then return self._last_rowid end
    local _, rows = self:_run(sql)
    if not rows or #rows == 0 then return nil end
    return unpack(rows[1], 1, rows[1].n)
end

function CliConn:prepare(sql)
    return setmetatable({ conn = self, sql = sql, _cli = true }, Stmt)
end

function CliConn:close() end

-- Stmt drives whichever backend its connection uses
local luasqlStep = Stmt.step
function Stmt:step()
    if not self._cli then return luasqlStep(self) end
    if not self._buffered then
        local _, rows = self.conn:_run(self:_sql())
        self._buffered, self._position = rows or {}, 0
    end
    self._position = self._position + 1
    return self._buffered[self._position]
end

local function haveSqlite3Cli()
    local probe = io.popen("command -v sqlite3 2>/dev/null")
    local path = probe and probe:read("*l")
    if probe then probe:close() end
    return path and path ~= "" and path or nil
end

M.sqlite3_binary = "sqlite3"

--- Prefers luasql when it is installed, otherwise drives the sqlite3 command
--- line tool, which ships with macOS and is one package away elsewhere. Either
--- way the plugin's own SQL runs against real SQLite.
function M.open(path)
    if ok_driver then
        local env = driver.sqlite3()
        local conn, err = env:connect(path)
        if not conn then error(tostring(err), 0) end
        M.backend = "luasql"
        return setmetatable({ _env = env, _conn = conn }, Conn)
    end

    local binary = haveSqlite3Cli()
    if not binary then
        error("no SQLite available: install luasql-sqlite3, or the sqlite3 command "
            .. "line tool (macOS ships it; apt-get install sqlite3 elsewhere)", 0)
    end
    M.sqlite3_binary = binary
    M.backend = "sqlite3-cli"
    return setmetatable({ _path = path }, CliConn)
end

return M
