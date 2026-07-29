local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local queryChatGPT = require("gpt_query")

local CONFIGURATION = nil

local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

-- What the assistant is told to do with a highlight. Override it by setting
-- features.explain_prompt in configuration.lua.
local DEFAULT_EXPLAIN_PROMPT = [[
You are helping someone understand the book they are reading. They have highlighted a passage.

Explain that passage so a curious non-expert can follow it:
- Say what it means in plain, everyday language.
- Give the background or context needed to make sense of it: who or what is being referred to, any unfamiliar terms, ideas or events, and anything the author is assuming the reader already knows.
- If the passage is making an argument or a point, say what that point is and why it matters.

Keep it short — a few brief paragraphs at most. Do not quote the passage back verbatim, and do not pad the answer with pleasantries.
]]

local TRANSLATE_SYSTEM_PROMPT =
  "You are a helpful translation assistant. Provide direct translations without additional commentary."

local function getFeature(name)
  return CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features[name]
end

local function showError(message)
  UIManager:show(InfoMessage:new{
    text = message,
    timeout = 10,
  })
end

-- Runs a blocking query behind a "Loading..." message, then hands the answer to
-- on_answer. Any failure is reported to the user instead of raising, because an
-- uncaught error in a scheduled task terminates KOReader.
local function runQuery(loading_text, message_history, on_answer)
  local loading = InfoMessage:new{ text = loading_text }
  UIManager:show(loading)
  -- Get the message on screen before we block on the network
  UIManager:forceRePaint()

  UIManager:nextTick(function()
    local answer, err = queryChatGPT(message_history)
    UIManager:close(loading)

    if not answer then
      showError(_("Could not get a response:") .. "\n\n" .. tostring(err))
      return
    end

    table.insert(message_history, {
      role = "assistant",
      content = answer,
    })
    on_answer(answer)
  end)
end

local function getBookContext(ui)
  local props = ui.document and ui.document:getProps() or {}
  return props.title or _("Unknown Title"), props.authors or _("Unknown Author")
end

-- message_history[1] is the system prompt and [2] the request we built for the
-- user, neither of which is worth showing. Everything from [3] on is the
-- conversation itself, starting with the answer.
local function createResultText(highlightedText, message_history)
  local result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"

  for i = 3, #message_history do
    local message = message_history[i]
    if message.role == "user" then
      result_text = result_text .. _("You: ") .. message.content .. "\n\n"
    elseif i == 3 then
      result_text = result_text .. message.content .. "\n\n"
    else
      result_text = result_text .. _("ChatGPT: ") .. message.content .. "\n\n"
    end
  end

  return result_text
end

local function showViewer(viewer_title, highlightedText, message_history)
  local function handleNewQuestion(chatgpt_viewer, question)
    table.insert(message_history, {
      role = "user",
      content = question,
    })

    runQuery(_("Asking ChatGPT…"), message_history, function()
      chatgpt_viewer:update(createResultText(highlightedText, message_history))
    end)
  end

  UIManager:show(ChatGPTViewer:new {
    title = viewer_title,
    text = createResultText(highlightedText, message_history),
    onAskQuestion = handleNewQuestion,
  })
end

-- Explain the highlight straight away, no question to type in.
local function explainHighlight(ui, highlightedText)
  local title, author = getBookContext(ui)
  local message_history = {
    {
      role = "system",
      content = getFeature("explain_prompt") or DEFAULT_EXPLAIN_PROMPT,
    },
    {
      role = "user",
      content = string.format(
        "I am reading '%s' by %s. Explain the following highlighted passage:\n\n%s",
        tostring(title), tostring(author), highlightedText),
    },
  }

  runQuery(_("Asking ChatGPT…"), message_history, function()
    showViewer(_("Explanation"), highlightedText, message_history)
  end)
end

local function translateHighlight(ui, highlightedText)
  local target_language = getFeature("translate_to")
  if not target_language then return end

  local message_history = {
    {
      role = "system",
      content = TRANSLATE_SYSTEM_PROMPT,
    },
    {
      role = "user",
      content = "Translate the following text to " .. target_language .. ": " .. highlightedText,
    },
  }

  runQuery(_("Translating…"), message_history, function()
    showViewer(_("Translation"), highlightedText, message_history)
  end)
end

local function isTranslationEnabled()
  return getFeature("translate_to") ~= nil
end

return {
  explain = explainHighlight,
  translate = translateHighlight,
  isTranslationEnabled = isTranslationEnabled,
}
