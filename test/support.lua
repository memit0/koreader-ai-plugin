-- Shared KOReader stubs for the Lunote tests. Real SQLite underneath (via
-- sq3shim), everything else faked just enough to drive the plugin's own code.
local HERE = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local SCRATCH = HERE .. "/tmp"
local PLUGIN = HERE:match("^(.*)[/\\][^/\\]*$") or ".."

package.path = PLUGIN .. "/?.lua;" .. HERE .. "/?.lua;" .. package.path
os.execute("mkdir -p " .. SCRATCH)

local M = { SCRATCH = SCRATCH, PLUGIN = PLUGIN }

-- Captures what the plugin tried to send, before encoding, so tests can assert
-- on payload structure directly.
M.http = { status = 200, response = {}, sent = {}, fail_after = nil, calls = 0 }
M.shown = {}
M.ticks = {}

local function fake_request(reqt)
    M.http.calls = M.http.calls + 1
    -- Where a request went, and with what credential, matters as much as its
    -- body now that explanations can be routed either to a provider directly or
    -- to the web app.
    M.http.url = reqt.url
    M.http.headers = reqt.headers
    if M.http.fail_after and M.http.calls > M.http.fail_after then
        return nil, "connection reset"
    end
    if reqt.sink then reqt.sink("RESPONSE") end
    return 1, M.http.status, {}, ""
end

local function fake_http_request(reqt)
    M.http.transport = "http"
    return fake_request(reqt)
end

local function fake_https_request(reqt)
    M.http.transport = "https"
    return fake_request(reqt)
end

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

M.events = {}

local modules = {
    ["lua-ljsqlite3/init"] = require("sq3shim"),
    ["datastorage"] = { getSettingsDir = function() return SCRATCH .. "/dbdir" end,
                        getDataDir = function() return SCRATCH end,
                        getFullDataDir = function() return SCRATCH end },
    ["device"] = { canUseWAL = function() return false end,
                   model = "TestReader",
                   hasClipboard = function() return true end,
                   hasKeys = function() return false end,
                   isTouchDevice = function() return false end,
                   screen = { getWidth = function() return 600 end,
                              getHeight = function() return 800 end,
                              scaleBySize = function(_, n) return n end },
                   input = { group = { Back = {} }, setClipboardText = function() end } },
    ["logger"] = { warn = function() end, dbg = function() end, info = function() end,
                   err = function() end },
    ["util"] = { partialMD5 = function(path) return "md5-" .. tostring(path) end,
                 cleanupSelectedText = function(s) return s end },
    -- Never fall through to the developer's real .env / process environment:
    -- tests that need a value (e.g. a custom sync endpoint) set it explicitly
    -- via History.setState instead. loadOptional still goes through the real
    -- (overridden) require, so lunote_config/api_key stubbing below still works.
    ["lunote_env"] = {
        get = function() return nil end,
        loadOptional = function(name)
            local ok, loaded = pcall(function() return require(name) end)
            if ok then return loaded end
            return nil
        end,
    },
    ["gettext"] = setmetatable({}, { __call = function(_, s) return s end }),
    ["ui/uimanager"] = {
        show = function(_, w) table.insert(M.shown, w) end,
        close = function() end,
        forceRePaint = function() end,
        nextTick = function(_, action) table.insert(M.ticks, action) end,
        scheduleIn = function(_, _, action) table.insert(M.ticks, action) end,
        setDirty = function() end,
    },
    ["ui/widget/infomessage"] = Widget:extend{ __kind = "InfoMessage" },
    ["ui/widget/confirmbox"] = Widget:extend{},
    ["ui/widget/inputdialog"] = Widget:extend{ getInputText = function() return "" end,
                                               onShowKeyboard = function() end },
    ["ui/widget/menu"] = Widget:extend{ __kind = "Menu" },
    ["ui/event"] = { new = function(_, name, payload)
                         table.insert(M.events, { name = name, payload = payload })
                         return { name = name, payload = payload }
                     end },
    ["ui/network/manager"] = { runWhenOnline = function(_, cb) cb() end },
    ["socket.http"] = { request = fake_http_request },
    ["ssl.https"] = { request = fake_https_request },
    ["ltn12"] = { source = { string = function(s) return s end } },
    ["mime"] = { b64 = function(s) return "base64:" .. s end },
    ["socketutil"] = {
        set_timeout = function() end, reset_timeout = function() end,
        LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
        table_sink = function(t)
            return function(chunk) if chunk then table.insert(t, chunk) end return 1 end, t
        end,
    },
    ["json"] = {
        encode = function(t) table.insert(M.http.sent, t) return "ENCODED" end,
        decode = function(s)
            if s == "RESPONSE" then return M.http.response end
            error("unexpected decode: " .. tostring(s))
        end,
    },
    -- viewer dependencies
    ["ui/bidi"] = {}, ["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 1 },
    ["ui/widget/buttontable"] = Widget:extend{ getSize = function() return { h = 1 } end,
                                               getButtonById = function() return nil end },
    ["ui/widget/container/centercontainer"] = Widget:extend{},
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    ["ui/widget/container/inputcontainer"] = InputContainer,
    ["ui/widget/checkbutton"] = Widget:extend{},
    ["ui/geometry"] = Widget:extend{},
    ["ui/font"] = { getFace = function() return {} end },
    ["ui/widget/container/framecontainer"] = Widget:extend{ getSize = function() return { h = 1 } end },
    ["ui/gesturerange"] = Widget:extend{},
    ["ui/widget/container/movablecontainer"] = Widget:extend{},
    ["ui/widget/notification"] = Widget:extend{},
    ["ui/widget/scrolltextwidget"] = Widget:extend{ scrollToBottom = function() end },
    ["ui/size"] = { padding = { large = 1, default = 1, small = 1 },
                    margin = { small = 1 }, radius = { window = 1 } },
    ["ui/widget/titlebar"] = Widget:extend{ getHeight = function() return 1 end },
    ["ui/widget/verticalgroup"] = Widget:extend{},
    ["ffi/util"] = { template = function(s) return s end },
    ["lunote_config"] = { api_key = "sk-test", model = "test-model", features = {} },
}

M.modules = modules

local real_require = require
_G.require = function(name)
    if modules[name] then return modules[name] end
    return real_require(name)
end

function M.reset()
    os.execute("rm -rf " .. SCRATCH .. "/dbdir && mkdir -p " .. SCRATCH .. "/dbdir")
    M.http.status, M.http.response = 200, {}
    M.http.sent, M.http.fail_after, M.http.calls, M.http.transport = {}, nil, 0, nil
    M.http.url, M.http.headers = nil, nil
    M.shown, M.ticks, M.events = {}, {}, {}
    modules["lunote_config"].features = {}
    for _, name in ipairs({ "lunote_history", "lunote_sync", "lunote_annotations", "lunote_dialogs", "lunote_env",
                            "lunote_query", "lunote_history_browser", "main", "lunote_update_checker" }) do
        package.loaded[name] = nil
    end
end

function M.drain()
    while #M.ticks > 0 do
        local action = table.remove(M.ticks, 1)
        action()
    end
end

local passed, failed = 0, 0
function M.check(label, condition, detail)
    if condition then
        passed = passed + 1
        print(string.format("  ok    %s", label))
    else
        failed = failed + 1
        print(string.format("  FAIL  %s%s", label, detail and ("  -> " .. tostring(detail)) or ""))
    end
end

function M.summary()
    print(string.format("\n%d passed, %d failed", passed, failed))
    if failed > 0 then os.exit(1) end
end

return M
