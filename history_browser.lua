--[[--
Browsing UI for the stored explanations: books, then that book's conversations,
then the transcript in the viewer the plugin already uses.
]]
local ChatGPTViewer = require("chatgptviewer")
local ConfirmBox = require("ui/widget/confirmbox")
local History = require("history")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local _ = require("gettext")

local HistoryBrowser = {}

local function formatDate(timestamp)
    if not timestamp then return "" end
    return os.date("%Y-%m-%d", tonumber(timestamp))
end

local function truncate(text, limit)
    text = (text or ""):gsub("%s+", " ")
    if #text <= limit then return text end
    return text:sub(1, limit) .. "…"
end

local function showTranscript(conversation)
    local messages = History.getMessages(conversation.id) or {}
    local body = _("Highlighted text: ") .. "\"" .. (conversation.highlight or "") .. "\"\n\n"
    for index, message in ipairs(messages) do
        if message.role == "user" then
            -- The first user turn is the prompt we built, not something the user typed
            if index > 2 then
                body = body .. _("You: ") .. message.content .. "\n\n"
            end
        else
            body = body .. message.content .. "\n\n"
        end
    end

    UIManager:show(ChatGPTViewer:new{
        title = conversation.chapter and conversation.chapter ~= "" and conversation.chapter
            or _("Explanation"),
        text = body,
    })
end

local function showConversations(book)
    local conversations = History.listConversations(book.id) or {}
    local menu
    local items = {}

    for _, conversation in ipairs(conversations) do
        items[#items + 1] = {
            text = string.format("%s  %s", formatDate(conversation.created_at),
                truncate(conversation.highlight, 60)),
            callback = function() showTranscript(conversation) end,
            hold_callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this explanation?"),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        History.deleteConversation(conversation.id)
                        UIManager:close(menu)
                        showConversations(book)
                    end,
                })
            end,
        }
    end

    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No explanations saved for this book yet."), timeout = 3 })
        return
    end

    menu = Menu:new{
        title = book.title ~= "" and book.title or _("Unknown Title"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function HistoryBrowser.show()
    local books = History.listBooks() or {}
    local menu
    local items = {}

    for _, book in ipairs(books) do
        local conversation_count = tonumber(book.n_conversations) or 0
        local item_count = tonumber(book.n_items) or 0
        items[#items + 1] = {
            text = string.format("%s  (%d)", book.title ~= "" and book.title or _("Unknown Title"),
                conversation_count),
            mandatory = string.format("%d ✎", item_count),
            callback = function() showConversations(book) end,
        }
    end

    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Nothing saved yet. Highlight a passage and tap Explain."), timeout = 4 })
        return
    end

    menu = Menu:new{
        title = _("AskGPT history"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

return HistoryBrowser
