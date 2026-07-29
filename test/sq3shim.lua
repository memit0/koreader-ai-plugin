-- Implements just enough of KOReader's lua-ljsqlite3 API on top of luasql.sqlite3
-- so the plugin's real SQL runs against real SQLite in tests: real UNIQUE
-- constraints, real transactions, real query planning.
--
-- ljsqlite3 conventions reproduced here:
--   conn:exec(sql)      -> column-oriented resultset (result[col][row]) or nil
--   conn:rowexec(sql)   -> first row's values, unpacked
--   conn:prepare(sql)   -> stmt; stmt:reset():bind(...):step() -> row array or nil
local driver = require("luasql.sqlite3")

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

function M.open(path)
    local env = driver.sqlite3()
    local conn, err = env:connect(path)
    if not conn then error(tostring(err), 0) end
    return setmetatable({ _env = env, _conn = conn }, Conn)
end

return M
