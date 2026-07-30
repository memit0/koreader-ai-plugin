--[[--
A KOReader stand-in for developing this plugin on a desktop.

The plugin's own modules are loaded **unmodified** and everything that carries
real risk is real: real SQLite, real HTTP to OpenRouter, real HTTP to the sync
endpoint, real annotation persistence. Only KOReader's widget layer is replaced,
with stubs faithful enough that the widgets still get constructed — so a mistake
in ConversationViewer:init() still surfaces here rather than on the device.

What this cannot tell you: how anything looks on e-ink, and whether
saveHighlight() finds positions in your particular document format. Those need
the real thing.
]]
local HERE = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
-- If HERE has no separator it is a directory directly under the working
-- directory, so the plugin root is "." rather than "..".
local PLUGIN = HERE:match("^(.*)[/\\][^/\\]*$") or "."
local DATA = HERE .. "/data"

package.path = table.concat({
    PLUGIN .. "/?.lua",
    HERE .. "/?.lua",
    PLUGIN .. "/test/?.lua", -- shares the ljsqlite3 shim with the test suite
    package.path,
}, ";")

os.execute("mkdir -p " .. DATA .. "/settings " .. DATA .. "/sidecar " .. DATA .. "/books")

-- A small pure-Lua codec, so the simulator needs no compiled modules
local cjson = require("json")

local M = {
    PLUGIN = PLUGIN,
    DATA = DATA,
    -- Everything the simulated UI has emitted, newest last
    output = {},
    -- Queued answers for the next InputDialog prompts
    input_queue = {},
    -- Widgets currently "on screen"
    stack = {},
    ticks = {},
    events = {},
    quiet = false,
}

local function emit(kind, text)
    table.insert(M.output, { kind = kind, text = text })
    if not M.quiet then
        io.write(text, "\n")
        io.flush()
    end
end
M.emit = emit

local function box(title, body)
    local width = 72
    local bar = string.rep("─", width)
    local lines = { "┌" .. bar .. "┐" }
    table.insert(lines, "│ " .. title .. string.rep(" ", math.max(0, width - #title - 1)) .. "│")
    table.insert(lines, "├" .. bar .. "┤")
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        -- crude wrap; enough to read prose in a terminal
        while #line > width - 2 do
            local cut = line:sub(1, width - 2):match("^(.*)%s%S*$") or line:sub(1, width - 2)
            table.insert(lines, "│ " .. cut .. string.rep(" ", width - #cut - 1) .. "│")
            line = line:sub(#cut + 2)
        end
        table.insert(lines, "│ " .. line .. string.rep(" ", math.max(0, width - #line - 1)) .. "│")
    end
    table.insert(lines, "└" .. bar .. "┘")
    return table.concat(lines, "\n")
end
M.box = box

-- Widget prototypes, matching frontend/ui/widget/widget.lua ------------------

local Widget = {}
function Widget:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
function Widget:new(o)
    o = self:extend(o)
    if o._init then o:_init() end
    if o.init then o:init() end
    return o
end
M.Widget = Widget

local WidgetContainer = Widget:extend{}
local InputContainer = WidgetContainer:extend{}
function InputContainer:_init()
    self.key_events = self.key_events or {}
    self.ges_events = self.ges_events or {}
end

-- Storage --------------------------------------------------------------------

-- Linux has md5sum, macOS has md5. Only the book identity depends on this, and
-- it just has to be stable, so falling back to size and path is acceptable.
local md5Command
local function findMd5Command()
    if md5Command ~= nil then return md5Command end
    for _, candidate in ipairs({ "md5sum", "md5 -q" }) do
        local binary = candidate:match("^%S+")
        local probe = io.popen("command -v " .. binary .. " 2>/dev/null")
        local found = probe and probe:read("*l")
        if probe then probe:close() end
        if found and found ~= "" then
            md5Command = candidate
            return md5Command
        end
    end
    md5Command = false
    return md5Command
end

local function md5OfFile(path)
    if not path then return nil end
    local probe = io.open(path, "rb")
    if not probe then return nil end
    local size = probe:seek("end")
    probe:close()

    local command = findMd5Command()
    if command then
        local pipe = io.popen(command .. " " .. string.format("%q", path) .. " 2>/dev/null")
        local line = pipe and pipe:read("*l")
        if pipe then pipe:close() end
        local digest = line and line:match("(%x%x%x%x%x%x%x+)")
        if digest then return digest end
    end

    return string.format("%08x-%s", size, path:gsub("%W", ""):sub(-16))
end

--- Annotations live in a per-book file, standing in for KOReader's .sdr
--- sidecar, so highlights and notes survive between runs and the
--- mirror-on-close path is worth exercising.
function M.loadSidecar(md5)
    local file = io.open(DATA .. "/sidecar/" .. (md5 or "unknown") .. ".json", "r")
    if not file then return {} end
    local raw = file:read("*a")
    file:close()
    local ok, decoded = pcall(cjson.decode, raw)
    return (ok and type(decoded) == "table") and decoded or {}
end

function M.saveSidecar(md5, annotations)
    local file = io.open(DATA .. "/sidecar/" .. (md5 or "unknown") .. ".json", "w")
    if not file then return end
    -- cjson turns an empty table into {}, which would not round-trip as a list
    file:write(#annotations == 0 and "[]" or cjson.encode(annotations))
    file:close()
end

-- Module table ---------------------------------------------------------------

local modules

local UIManager = {
    show = function(_, widget)
        table.insert(M.stack, widget)
        M.render(widget)
    end,
    close = function(_, widget)
        for index = #M.stack, 1, -1 do
            if M.stack[index] == widget then table.remove(M.stack, index) end
        end
    end,
    forceRePaint = function() end,
    setDirty = function() end,
    nextTick = function(_, action) table.insert(M.ticks, action) end,
    scheduleIn = function(_, _, action) table.insert(M.ticks, action) end,
    askForRestart = function() emit("info", "[restart would be requested]") end,
}

--- Renders whatever the plugin just showed. Recognises the widget by the marker
--- its stub carries, so plugin code needs no simulator-specific branches.
function M.render(widget)
    if widget.__kind == "InfoMessage" then
        emit("info", "  » " .. tostring(widget.text))
    elseif widget.__kind == "ConversationViewer" then
        emit("viewer", box(tostring(widget.title or "Viewer"), tostring(widget.text or "")))
        M.viewer = widget
    elseif widget.__kind == "Menu" then
        local lines = { "", tostring(widget.title or "Menu") }
        for index, item in ipairs(widget.item_table or {}) do
            local label = type(item.text) == "function" and item.text() or item.text
            lines[#lines + 1] = string.format("  %2d. %s%s", index, tostring(label),
                item.mandatory and ("   " .. tostring(item.mandatory)) or "")
        end
        lines[#lines + 1] = "  (use `pick <n>` to choose)"
        emit("menu", table.concat(lines, "\n"))
        M.menu = widget
    elseif widget.__kind == "InputDialog" then
        emit("input", "  ? " .. tostring(widget.title or "Input")
            .. (widget.description and ("  — " .. widget.description) or ""))
        M.dialog = widget
    elseif widget.__kind == "ConfirmBox" then
        emit("confirm", "  ? " .. tostring(widget.text) .. "  (auto-confirming)")
        if widget.ok_callback then widget.ok_callback() end
    end
end

--- Runs everything the plugin scheduled. The plugin defers its blocking network
--- calls to nextTick, so this is where the real work happens.
function M.drain()
    local guard = 0
    while #M.ticks > 0 and guard < 1000 do
        guard = guard + 1
        local action = table.remove(M.ticks, 1)
        local ok, err = pcall(action)
        if not ok then emit("error", "  !! scheduled task raised: " .. tostring(err)) end
    end
end

local InfoMessage = Widget:extend{ __kind = "InfoMessage" }
local ConversationViewerStub = Widget:extend{ __kind = "ConversationViewer" }
local MenuStub = Widget:extend{ __kind = "Menu" }
local ConfirmBox = Widget:extend{ __kind = "ConfirmBox" }

local InputDialog = Widget:extend{ __kind = "InputDialog" }
function InputDialog:getInputText()
    local queued = table.remove(M.input_queue, 1)
    if queued then emit("input", "  > " .. queued) end
    return queued or ""
end
function InputDialog:onShowKeyboard() end

-- Mock LLM ------------------------------------------------------------------
-- On by default, so the simulator works with no API key, no network and no
-- spend. `mock off` in the console (or LUNOTE_SIM_MOCK=0) sends the real thing.
-- Only completion requests are intercepted; sync traffic always goes out.

M.mock_llm = os.getenv("LUNOTE_SIM_MOCK") ~= "0"

function M.fakeCompletion(request)
    local answer = table.concat({
        "[mock answer — the simulator did not call a real model]",
        "",
        "This stands in for the explanation. It is long enough to exercise",
        "wrapping, note appending and the viewer, and it is labelled so it can",
        "never be mistaken for real model output.",
    }, "\n")
    local body = cjson.encode({
        model = "sim/mock-model",
        choices = { { message = { role = "assistant", content = answer } } },
    })
    if request.sink then
        request.sink(body)
        request.sink(nil) -- ltn12 sinks expect the terminating nil
    end
    return 1, 200, {}, "HTTP/1.1 200 OK"
end

local function withMockedCompletions(real)
    return setmetatable({
        request = function(request, ...)
            if M.mock_llm and type(request) == "table"
                and tostring(request.url):find("chat/completions", 1, true) then
                emit("log", "  [mock] intercepted " .. tostring(request.url))
                return M.fakeCompletion(request)
            end
            return real.request(request, ...)
        end,
    }, { __index = real })
end

modules = {
    -- Real, because these are where the bugs live
    ["socket.http"] = withMockedCompletions(require("socket.http")),
    ["ssl.https"] = withMockedCompletions(require("ssl.https")),
    ["ltn12"] = require("ltn12"),
    ["json"] = { encode = cjson.encode, decode = cjson.decode },
    ["lua-ljsqlite3/init"] = require("sq3shim"),

    ["socketutil"] = (function()
        local http = require("socket.http")
        local socketutil = {
            LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
            DEFAULT_BLOCK_TIMEOUT = 60,
        }
        function socketutil:set_timeout(block) http.TIMEOUT = block or 60 end
        function socketutil:reset_timeout() http.TIMEOUT = 60 end
        function socketutil.table_sink(t)
            return require("ltn12").sink.table(t), t
        end
        return socketutil
    end)(),

    ["datastorage"] = {
        getSettingsDir = function() return DATA .. "/settings" end,
        getDataDir = function() return DATA end,
        getFullDataDir = function() return DATA end,
    },
    ["device"] = {
        model = "DesktopSimulator",
        canUseWAL = function() return true end,
        hasClipboard = function() return true end,
        hasKeys = function() return false end,
        isTouchDevice = function() return true end,
        canShareText = function() return false end,
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_, n) return n end,
        },
        input = { group = { Back = {} }, setClipboardText = function() end },
    },
    ["logger"] = {
        warn = function(...) emit("log", "  [warn] " .. table.concat({ ... }, " ")) end,
        err = function(...) emit("log", "  [err]  " .. table.concat({ ... }, " ")) end,
        info = function() end,
        dbg = function() end,
    },
    ["util"] = {
        partialMD5 = md5OfFile,
        cleanupSelectedText = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
    },
    ["gettext"] = setmetatable({}, { __call = function(_, s) return s end }),
    ["ui/uimanager"] = UIManager,
    ["ui/widget/infomessage"] = InfoMessage,
    ["ui/widget/confirmbox"] = ConfirmBox,
    ["ui/widget/inputdialog"] = InputDialog,
    ["ui/widget/menu"] = MenuStub,
    ["ui/event"] = {
        new = function(_, name, payload)
            table.insert(M.events, { name = name, payload = payload })
            return { name = name, payload = payload }
        end,
    },
    ["ui/network/manager"] = {
        runWhenOnline = function(_, callback) callback() end,
    },

    -- Widget dependencies of the real ConversationViewer, stubbed but constructed
    ["ui/bidi"] = { flipDirectionIfMirroredUILayout = function(d) return d end },
    ["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 1 },
    ["ui/widget/buttontable"] = Widget:extend{
        getSize = function() return { h = 1 } end,
        getButtonById = function() return nil end,
    },
    ["ui/widget/container/centercontainer"] = Widget:extend{},
    ["ui/widget/container/framecontainer"] = Widget:extend{
        getSize = function() return { h = 1 } end,
    },
    ["ui/widget/container/movablecontainer"] = Widget:extend{},
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    ["ui/widget/container/inputcontainer"] = InputContainer,
    ["ui/widget/checkbutton"] = Widget:extend{},
    ["ui/geometry"] = Widget:extend{},
    ["ui/font"] = { getFace = function() return {} end },
    ["ui/gesturerange"] = Widget:extend{},
    ["ui/widget/notification"] = Widget:extend{},
    ["ui/widget/scrolltextwidget"] = Widget:extend{
        scrollToBottom = function() end, scrollToTop = function() end,
    },
    ["ui/size"] = {
        padding = { large = 1, default = 1, small = 1 },
        margin = { small = 1 }, radius = { window = 1 },
    },
    ["ui/widget/titlebar"] = Widget:extend{ getHeight = function() return 1 end },
    ["ui/widget/verticalgroup"] = Widget:extend{},
    ["ffi/util"] = { template = function(s) return s end },
}

M.modules = modules

-- The plugin's own ConversationViewer is real code, so load it and keep its text
-- while presenting it to the console as a viewer.
local realRequire = require
_G.require = function(name)
    if modules[name] then return modules[name] end
    return realRequire(name)
end

local RealViewer = realRequire("lunote_viewer")
modules["lunote_viewer"] = setmetatable({
    new = function(_, options)
        -- Construct the real widget so its init() is genuinely exercised, then
        -- hand the console something it can print.
        local ok, err = pcall(RealViewer.new, RealViewer, {
            title = options.title, text = options.text,
            onAskQuestion = options.onAskQuestion,
        })
        if not ok then
            emit("error", "  !! ConversationViewer:init() raised: " .. tostring(err))
        end
        local widget = ConversationViewerStub:new{
            title = options.title, text = options.text,
            onAskQuestion = options.onAskQuestion,
        }
        widget.update = function(self, new_text)
            self.text = new_text
            emit("viewer", box(tostring(self.title), tostring(new_text)))
        end
        return widget
    end,
}, { __index = RealViewer })

function M.reset()
    M.output, M.stack, M.ticks, M.events = {}, {}, {}, {}
    M.viewer, M.menu, M.dialog = nil, nil, nil
    for _, name in ipairs({ "lunote_history", "lunote_sync", "lunote_annotations", "lunote_dialogs", "lunote_env",
                            "lunote_query", "lunote_history_browser", "main", "lunote_update_checker" }) do
        package.loaded[name] = nil
    end
end

M.md5OfFile = md5OfFile

return M
