--[[--
Pushes the local store to the web app.

Built around the assumption that e-reader wifi drops mid-transfer:

* work goes out in small batches, keyset paginated, so memory is flat and a batch
  costs the same whether it is the first or the thousandth;
* every record carries a stable uuid and the server upserts on it, so re-sending a
  batch is a no-op rather than a duplicate;
* each batch is marked synced only after the server acknowledges it, so a failure
  half way through keeps the earlier batches done and simply retries the rest;
* control returns to the UI between batches, so the reader stays responsive and
  Cancel actually works.

Push only: the device is the source of truth and the web app displays. No conflict
resolution, no pull cursor.
]]
local History = require("lunote_history")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local socketutil = require("socketutil")
local logger = require("logger")
local _ = require("gettext")

local Env = require("lunote_env")

local Sync = {}

local BATCH_SIZE = 25
local DEFAULT_ENDPOINT = "https://lunote.xyz"

local function endpoint()
    return History.getState("endpoint") or Env.get("LUNOTE_SYNC_URL") or DEFAULT_ENDPOINT
end

function Sync.getToken()
    return History.getState("token")
end

function Sync.isConfigured()
    local token = Sync.getToken()
    return token ~= nil and token ~= ""
end

-- The server tells us how explanations should be generated for this account:
-- once when pairing, and again with every sync, because a plan can start or
-- lapse long after the device was paired. "managed" means the pairing token is
-- also the credential, and there is no API key to configure.
local function rememberAiConfig(response)
    local ai = response and response.ai
    if type(ai) ~= "table" then return end
    if ai.mode == "managed" and type(ai.url) == "string" and ai.url ~= "" then
        History.setState("ai_mode", "managed")
        History.setState("ai_url", ai.url)
    else
        History.setState("ai_mode", "")
    end
end

--- Where to send explanations when the web app is generating them for us, or nil
--- when this device should be using its own key.
function Sync.getManagedUrl()
    if History.getState("ai_mode") ~= "managed" then return nil end
    local url = History.getState("ai_url")
    if not url or url == "" then return nil end
    return url
end

-- One JSON request, with the same timeouts KOReader's own exporters use. Returns
-- the decoded body, or nil plus a message. Never raises.
local function post(path, body, token)
    local encoded_ok, payload = pcall(json.encode, body)
    if not encoded_ok then
        return nil, "Could not encode the request: " .. tostring(payload)
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#payload),
    }
    if token then headers["Authorization"] = "Bearer " .. token end

    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local request = endpoint():match("^https://") and https.request or http.request
    local ok, res, code = pcall(request, {
        url = endpoint() .. path,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(payload),
        sink = socketutil.table_sink(sink),
    })
    socketutil:reset_timeout()

    if not ok then return nil, "Could not reach the server: " .. tostring(res) end
    if not res then return nil, "Could not reach the server: " .. tostring(code) end

    local response_body = table.concat(sink)
    if code ~= 200 then
        local decoded_ok, decoded = pcall(json.decode, response_body)
        if decoded_ok and type(decoded) == "table" and decoded.error then
            return nil, tostring(decoded.error)
        end
        return nil, "Server returned HTTP " .. tostring(code)
    end

    local decoded_ok, decoded = pcall(json.decode, response_body)
    if not decoded_ok then return nil, "Could not understand the server response." end
    return decoded
end

--- Exchanges a short pairing code shown by the web app for a long-lived device
--- token. Six characters is a lot friendlier than a 40-character token on an
--- e-ink keyboard.
function Sync.pair(code)
    local device_uuid = History.getState("device_uuid")
    local response, err = post("/api/v1/pair", {
        code = code,
        device_uuid = device_uuid,
        device_name = require("device").model,
    })
    if not response then return nil, err end
    if not response.token then return nil, "The server did not return a token." end
    History.setState("token", response.token)
    -- On a paid account this is the entire setup: the reply to six typed
    -- characters carries both the credential and where to use it, so nothing has
    -- to be written into a file on the device.
    rememberAiConfig(response)
    return true
end

function Sync.unpair()
    History.setState("token", "")
    -- The token was the credential for managed explanations too, so unpairing
    -- has to put the device back on its own key rather than leave it pointing at
    -- an endpoint it can no longer authenticate to.
    History.setState("ai_mode", "")
end

-- Drives one table's outbox to completion, a batch at a time. `progress` is
-- called between batches so the caller can update the UI and check for a cancel.
local function pushTable(table_name, fetch, token, progress)
    local cursor, sent = 0, 0
    while true do
        local batch = fetch(cursor, BATCH_SIZE)
        if not batch or #batch.records == 0 then return sent end

        local payload = { books = batch.books }
        payload[table_name == "item" and "items" or "conversations"] = batch.records

        local response, err = post("/api/v1/sync", payload, token)
        if not response then return sent, err end
        rememberAiConfig(response)

        -- Only now is it safe to clear the flags
        History.markSynced(table_name, batch.ids)
        History.markCoverSent(batch.cover_ids)
        sent = sent + #batch.records
        cursor = batch.cursor

        if progress and progress(sent) == false then
            return sent, "cancelled"
        end
        if #batch.records < BATCH_SIZE then return sent end
    end
end

--- Pushes everything outstanding. `callbacks.progress(n)` may return false to stop
--- at the next batch boundary; `callbacks.done(sent, err)` gets the outcome.
function Sync.run(callbacks)
    callbacks = callbacks or {}
    local token = Sync.getToken()
    if not token or token == "" then
        if callbacks.done then callbacks.done(0, "Not paired with the web app yet.") end
        return
    end

    -- Annotations first: the web app groups explanations under their highlight,
    -- so the highlight should already exist when the conversation lands.
    local sent_items, err = pushTable("item", History.getDirtyItems, token, callbacks.progress)
    if err then
        if callbacks.done then callbacks.done(sent_items, err) end
        return
    end

    local sent_conversations, conversation_err =
        pushTable("conversation", History.getDirtyConversations, token, callbacks.progress)

    if not conversation_err then
        History.setState("last_sync_at", os.time())
    end
    if callbacks.done then
        callbacks.done(sent_items + sent_conversations, conversation_err)
    end
end

--- Runs a sync with a progress message, yielding to the UI between batches so the
--- reader never appears frozen.
function Sync.runInteractive()
    local outstanding = History.countDirty() or 0
    if outstanding == 0 then
        UIManager:show(InfoMessage:new{ text = _("Everything is already synced."), timeout = 3 })
        return
    end

    local message = InfoMessage:new{ text = _("Syncing…") }
    UIManager:show(message)
    UIManager:forceRePaint()

    UIManager:nextTick(function()
        Sync.run{
            progress = function(sent)
                logger.dbg("Lunote sync: sent", sent)
            end,
            done = function(sent, err)
                UIManager:close(message)
                if err then
                    UIManager:show(InfoMessage:new{
                        text = _("Sync stopped:") .. "\n\n" .. tostring(err)
                            .. "\n\n" .. _("Synced so far: ") .. tostring(sent)
                            .. "\n" .. _("The rest will be retried next time."),
                        timeout = 10,
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Synced ") .. tostring(sent) .. _(" item(s)."),
                        timeout = 3,
                    })
                end
            end,
        }
    end)
end

return Sync
