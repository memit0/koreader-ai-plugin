--[[--
Interactive driver for the KOReader simulator. See dev/README.md.

    ./dev/askgpt-sim                 interactive
    ./dev/askgpt-sim dev/scripts/smoke.txt   run a script
]]
local HERE = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local ko = dofile(HERE .. "/kosim.lua")

local History = require("history")
local Sync = require("sync")

local state = { book = nil, ui = nil, plugin = nil, instance = nil, selection = nil }

local function say(text) ko.emit("sim", text) end

local SAMPLE = {
    title = "Critique of Pure Reason",
    authors = "Immanuel Kant",
    file = ko.DATA .. "/books/kant.txt",
}

local function ensureSampleBook()
    local existing = io.open(SAMPLE.file, "r")
    if existing then existing:close() return end
    local file = assert(io.open(SAMPLE.file, "w"))
    file:write([[
Two things fill the mind with ever new and increasing admiration and awe, the
oftener and the more steadily we reflect on them: the starry heavens above and
the moral law within.

Act only according to that maxim whereby you can at the same time will that it
should become a universal law.

Thoughts without content are empty, intuitions without concepts are blind.
]])
    file:close()
end

--- Builds the `ui` table ReaderUI would hand a plugin, backed by the simulated
--- sidecar so annotations persist between runs.
local function openBook(title, authors)
    ensureSampleBook()
    local book = {
        title = title or SAMPLE.title,
        authors = authors or SAMPLE.authors,
        file = SAMPLE.file,
    }
    book.md5 = ko.md5OfFile(book.file) or "nomd5"

    local annotations = ko.loadSidecar(book.md5)
    local ui

    local highlight = {
        _highlight_buttons = {},
        selected_text = nil,
        addToHighlightDialog = function(self, key, builder)
            self._highlight_buttons[key] = builder
        end,
        onClose = function() end,
        saveHighlight = function(self)
            if not self.selected_text then return nil end
            table.insert(annotations, {
                datetime = os.date("%Y-%m-%d %H:%M:%S"),
                text = self.selected_text.text,
                chapter = "Chapter " .. tostring(math.max(1, #annotations)),
                pageno = 10 * (#annotations + 1),
            })
            return #annotations
        end,
    }

    ui = {
        annotation = { annotations = annotations },
        document = {
            file = book.file,
            getProps = function() return { title = book.title, authors = book.authors } end,
        },
        toc = { getTocTitleByPage = function() return "Chapter 1" end },
        menu = { registerToMainMenu = function() end },
        highlight = highlight,
        handleEvent = function(_, event)
            -- Persist like KOReader does when annotations change
            if event.name == "AnnotationsModified" then
                ko.saveSidecar(book.md5, annotations)
            end
        end,
    }

    state.book = book
    state.ui = ui
    state.selection = nil
    state.plugin = dofile(ko.PLUGIN .. "/main.lua")
    state.instance = state.plugin:new{ ui = ui, view = {}, document = ui.document }
    say(string.format("opened %q by %s  (%d annotation(s), md5 %s)",
        book.title, book.authors, #annotations, book.md5:sub(1, 8)))
end

local function requireBook()
    if not state.ui then
        say("no book open — try `open`")
        return false
    end
    return true
end

local function pressHighlightButton(key, index)
    if not requireBook() then return end
    local builder = state.ui.highlight._highlight_buttons[key]
    if not builder then
        say("no such highlight button: " .. key
            .. " (available: " .. table.concat((function()
                local keys = {}
                for k in pairs(state.ui.highlight._highlight_buttons) do keys[#keys + 1] = k end
                table.sort(keys)
                return keys
            end)(), ", ") .. ")")
        return
    end
    local button = builder(state.ui.highlight, index)
    say("pressing “" .. tostring(button.text) .. "”" .. (index and (" on annotation " .. index) or ""))
    button.callback()
    ko.drain()
end

local commands = {}

commands.help = function()
    say([[
  book
    open [title | author]     open a book (defaults to the bundled sample)
    close                     close it, mirroring annotations into the store
    select <text>             set the current text selection
    notes                     list the book's annotations, as Bookmarks would

  the plugin
    explain                   press Explain on the current selection
    explain <n>               press Explain on existing annotation n
    translate                 press AI Translate (needs features.translate_to)
    ask <question>            follow up in the open viewer
    menu                      show the plugin's main menu
    pick <n>                  choose an item from the last menu shown

  storage and sync
    books                     books in the local store
    conv <book n>             conversations for that book
    status                    token, endpoint, outstanding records
    pair <code>               pair against the sync endpoint
    sync                      push everything outstanding
    sql <query>               run SQL against the store

  the model
    mock [on|off]             mock LLM (on by default: no key, no cost)

  misc
    reset                     wipe the simulator's data directory
    help, quit]])
end

commands.open = function(argument)
    local title, authors = nil, nil
    if argument and argument ~= "" then
        title, authors = argument:match("^(.-)%s*|%s*(.+)$")
        title = title or argument
    end
    openBook(title, authors)
end

commands.close = function()
    if not requireBook() then return end
    state.instance:onCloseDocument()
    say("closed; annotations mirrored into the store")
end

commands.select = function(argument)
    if not requireBook() then return end
    if not argument or argument == "" then
        say("usage: select <text>")
        return
    end
    state.ui.highlight.selected_text = { text = argument }
    state.selection = argument
    say("selected: " .. argument)
end

commands.explain = function(argument)
    local index = tonumber(argument)
    if index then
        if not requireBook() then return end
        local annotation = state.ui.annotation.annotations[index]
        if not annotation then
            say("no annotation " .. index .. " — try `notes`")
            return
        end
        state.ui.highlight.selected_text = { text = annotation.text }
    elseif not state.selection then
        say("nothing selected — try `select <text>` first")
        return
    end
    pressHighlightButton("askgpt_01_explain", index)
end

commands.translate = function()
    pressHighlightButton("askgpt_02_translate", nil)
end

commands.ask = function(argument)
    if not ko.viewer then
        say("no viewer open — run `explain` first")
        return
    end
    if not argument or argument == "" then
        say("usage: ask <question>")
        return
    end
    ko.viewer:onAskQuestion(argument)
    ko.drain()
end

commands.notes = function()
    if not requireBook() then return end
    local annotations = state.ui.annotation.annotations
    if #annotations == 0 then
        say("no annotations yet")
        return
    end
    for index, annotation in ipairs(annotations) do
        say(string.format("  %2d. [%s p.%s] %s", index,
            tostring(annotation.chapter), tostring(annotation.pageno),
            tostring(annotation.text)))
        if annotation.note then
            for line in (annotation.note .. "\n"):gmatch("([^\n]*)\n") do
                say("      | " .. line)
            end
        end
    end
end

commands.menu = function()
    if not state.instance then
        say("open a book first (or the file-manager menu, which needs no book)")
        return
    end
    local items = {}
    state.instance:addToMainMenu(items)
    local entry = items.askgpt
    local widget = ko.modules["ui/widget/menu"]:new{
        title = entry.text,
        item_table = entry.sub_item_table,
    }
    ko.render(widget)
end

commands.pick = function(argument)
    local index = tonumber(argument)
    if not (ko.menu and index) then
        say("usage: pick <n>, after a menu has been shown")
        return
    end
    local item = ko.menu.item_table[index]
    if not item then
        say("no item " .. tostring(argument))
        return
    end
    local label = type(item.text) == "function" and item.text() or item.text
    say("picking “" .. tostring(label) .. "”")
    if item.enabled_func and item.enabled_func() == false then
        say("  (that item is disabled)")
        return
    end
    if item.callback then item.callback() end
    ko.drain()
end

commands.books = function()
    local books = History.listBooks() or {}
    if #books == 0 then say("no books in the store yet") return end
    for index, book in ipairs(books) do
        say(string.format("  %2d. %s — %s  (%s highlight(s), %s explanation(s))",
            index, tostring(book.title), tostring(book.authors),
            tostring(book.n_items), tostring(book.n_conversations)))
    end
end

commands.conv = function(argument)
    local position = tonumber(argument) or 1
    local books = History.listBooks() or {}
    local book = books[position]
    if not book then say("no book " .. tostring(argument) .. " — try `books`") return end
    local conversations = History.listConversations(book.id) or {}
    if #conversations == 0 then say("no conversations for " .. tostring(book.title)) return end
    for index, conversation in ipairs(conversations) do
        say(string.format("  %2d. [%s] %s", index, tostring(conversation.kind),
            tostring(conversation.highlight)))
        for _, message in ipairs(History.getMessages(conversation.id) or {}) do
            say(string.format("      %-9s %s", message.role .. ":",
                message.content:sub(1, 100)))
        end
    end
end

commands.status = function()
    local token = Sync.getToken()
    say("  database   " .. History.DB_PATH)
    say("  device     " .. tostring(History.getState("device_uuid")))
    say("  endpoint   " .. tostring(History.getState("endpoint")
        or os.getenv("ASKGPT_SYNC_URL") or "(default)"))
    say("  paired     " .. (token and token ~= "" and ("yes (" .. token:sub(1, 8) .. "…)") or "no"))
    say("  last sync  " .. tostring(History.getState("last_sync_at") or "never"))
    say("  pending    " .. tostring(History.countDirty()))
end

commands.pair = function(argument)
    if not argument or argument == "" then say("usage: pair <code>") return end
    local ok, err = Sync.pair(argument)
    say(ok and "paired" or ("could not pair: " .. tostring(err)))
end

commands.sync = function()
    local finished = false
    Sync.run{
        progress = function(sent) say("  … " .. sent .. " sent") end,
        done = function(sent, err)
            finished = true
            say(err and string.format("sync stopped after %d: %s", sent, tostring(err))
                or string.format("synced %d record(s)", sent))
        end,
    }
    if not finished then say("sync did not report completion") end
end

commands.sql = function(argument)
    if not argument or argument == "" then say("usage: sql <query>") return end
    local result = History.withConn(function(conn) return conn:exec(argument) end)
    if not result then say("  (no rows)") return end
    local columns = {}
    for key in pairs(result) do
        if type(key) == "string" then columns[#columns + 1] = key end
    end
    table.sort(columns)
    say("  " .. table.concat(columns, " | "))
    for row = 1, #result[1] do
        local cells = {}
        for _, column in ipairs(columns) do
            cells[#cells + 1] = tostring(result[column][row]):sub(1, 40)
        end
        say("  " .. table.concat(cells, " | "))
    end
end

commands.reset = function()
    os.execute("rm -rf " .. ko.DATA .. "/settings " .. ko.DATA .. "/sidecar")
    os.execute("mkdir -p " .. ko.DATA .. "/settings " .. ko.DATA .. "/sidecar")
    ko.reset()
    History = require("history")
    Sync = require("sync")
    state.book, state.ui, state.instance = nil, nil, nil
    say("data directory wiped")
end

commands.mock = function(argument)
    if argument == "on" then ko.mock_llm = true
    elseif argument == "off" then ko.mock_llm = false
    elseif argument and argument ~= "" then say("usage: mock [on|off]") return end
    say("mock LLM is " .. (ko.mock_llm and "on — no API calls, no spend"
        or "off — real requests to your configured provider"))
end

commands.quit = function() state.quit = true end
commands.exit = commands.quit

-- Entry point ----------------------------------------------------------------

local function dispatch(line)
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" or line:sub(1, 1) == "#" then return end
    local name, argument = line:match("^(%S+)%s*(.*)$")
    local command = commands[name]
    if not command then
        say("unknown command: " .. name .. "  (try `help`)")
        return
    end
    local ok, err = pcall(command, argument)
    if not ok then say("!! " .. tostring(err)) end
end

local script = arg and arg[1]
if script then
    local file = assert(io.open(script, "r"), "cannot open script: " .. tostring(script))
    for line in file:lines() do
        if line:gsub("%s", "") ~= "" and line:sub(1, 1) ~= "#" then
            io.write("\n$ ", line, "\n")
        end
        dispatch(line)
        if state.quit then break end
    end
    file:close()
else
    io.write("KOReader simulator for AskGPT — `help` for commands, `quit` to leave\n")
    commands.status()
    while not state.quit do
        io.write("\naskgpt> ")
        io.flush()
        local line = io.read("*l")
        if not line then break end
        dispatch(line)
    end
end
