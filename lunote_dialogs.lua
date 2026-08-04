local ConversationViewer = require("lunote_viewer")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local queryModel = require("lunote_query")
local Annotations = require("lunote_annotations")
local History = require("lunote_history")
local Obsidian = require("lunote_obsidian")
local Sync = require("lunote_sync")
local Env = require("lunote_env")

local CONFIGURATION = Env.loadOptional("lunote_config")

-- What the assistant is told to do with a highlight. Override it by setting
-- features.explain_prompt in lunote_config.lua.
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
local function runQuery(loading_text, message_history, on_answer, on_error)
  local loading = InfoMessage:new{ text = loading_text }
  UIManager:show(loading)
  -- Get the message on screen before we block on the network
  UIManager:forceRePaint()

  UIManager:nextTick(function()
    local answer, err, model = queryModel(message_history)
    UIManager:close(loading)

    if not answer then
      if on_error then on_error() end
      showError(_("Could not get a response:") .. "\n\n" .. tostring(err))
      return
    end

    table.insert(message_history, {
      role = "assistant",
      content = answer,
    })
    on_answer(answer, model)
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
      result_text = result_text .. _("Reply: ") .. message.content .. "\n\n"
    end
  end

  return result_text
end

-- `conversation_id` is nil when the exchange was not recorded (a failed write, or
-- a translation with logging off); follow-ups then simply are not recorded either.
local function showViewer(viewer_title, highlightedText, message_history, conversation_id)
  local function handleNewQuestion(conversation_viewer, question)
    table.insert(message_history, {
      role = "user",
      content = question,
    })

    runQuery(_("Asking…"), message_history, function(answer)
      if conversation_id then
        History.appendMessages(conversation_id, {
          { role = "user", content = question },
          { role = "assistant", content = answer },
        })
      end
      conversation_viewer:update(createResultText(highlightedText, message_history))
    end, function()
      table.remove(message_history)
    end)
  end

  UIManager:show(ConversationViewer:new {
    title = viewer_title,
    text = createResultText(highlightedText, message_history),
    onAskQuestion = handleNewQuestion,
  })
end

-- Explain the highlight straight away, no question to type in.
-- `index` is the annotation index when an existing highlight was long-pressed.
local function explainHighlight(ui, highlightedText, index)
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

  runQuery(_("Asking…"), message_history, function(answer, model)
    -- Attach to the book's own annotation first, so the explanation shows up in
    -- Bookmarks next to the highlight and the user's notes.
    local annotation
    if getFeature("save_to_notes") ~= false then
      annotation = Annotations.saveToBook(ui, index, answer)
    end

    local conversation_id = History.startConversation{
      book = Annotations.getBook(ui),
      kind = "explain",
      highlight = highlightedText,
      chapter = annotation and annotation.chapter,
      pageno = annotation and annotation.pageno,
      annotation_datetime = annotation and annotation.datetime,
      model = model,
      messages = {
        { role = "user", content = highlightedText },
        { role = "assistant", content = answer },
      },
    }

    showViewer(_("Explanation"), highlightedText, message_history, conversation_id)
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

  runQuery(_("Translating…"), message_history, function(answer, model)
    -- Translations stay out of your notes, and out of the history unless asked for
    local conversation_id
    if getFeature("log_translations") then
      conversation_id = History.startConversation{
        book = Annotations.getBook(ui),
        kind = "translate",
        highlight = highlightedText,
        model = model,
        messages = {
          { role = "user", content = highlightedText },
          { role = "assistant", content = answer },
        },
      }
    end
    showViewer(_("Translation"), highlightedText, message_history, conversation_id)
  end)
end

local function isTranslationEnabled()
  return getFeature("translate_to") ~= nil
end

local function showPairingDialog()
  local dialog
  dialog = InputDialog:new{
    title = _("Pair with the web app"),
    description = _("Enter the code shown on the web app."),
    input = "",
    input_type = "text",
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function() UIManager:close(dialog) end,
        },
        {
          text = _("Pair"),
          is_enter_default = true,
          callback = function()
            local code = dialog:getInputText()
            UIManager:close(dialog)
            if not code or code == "" then return end
            NetworkMgr:runWhenOnline(function()
              local ok, err = Sync.pair(code)
              UIManager:show(InfoMessage:new{
                text = ok and _("Paired. You can sync now.")
                  or (_("Could not pair:") .. "\n\n" .. tostring(err)),
                timeout = ok and 3 or 10,
              })
            end)
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
  dialog:onShowKeyboard()
end

-- Obsidian --------------------------------------------------------------------

local function reportVaultSet(vault, err, on_change)
  if not vault then
    showError(_("Could not use that folder:") .. "\n\n" .. tostring(err))
    return
  end
  if on_change then on_change() end
  local text = _("Vault folder set:") .. "\n\n" .. vault
  if not Obsidian.looksLikeVault(vault) then
    -- Not an error: an empty folder becomes a vault the moment Obsidian opens
    -- it. Worth saying, because a mistyped path looks exactly like this too.
    text = text .. "\n\n" .. _("No .obsidian folder found there yet.")
  end
  UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
end

--- Stores the address and key, then says whether Obsidian actually answered —
--- the only way to find out you mistyped one of them without going looking for
--- notes that were never going to arrive.
local function saveObsidianServer(address, api_key, on_change)
  local url, err = Obsidian.setServer(address, api_key)
  if not url then
    showError(_("Could not use that:") .. "\n\n" .. tostring(err))
    return
  end
  if on_change then on_change() end

  local checking = InfoMessage:new{ text = _("Checking…") }
  UIManager:show(checking)
  UIManager:forceRePaint()
  UIManager:nextTick(function()
    local ok, detail = Obsidian.testConnection()
    UIManager:close(checking)
    UIManager:show(InfoMessage:new{
      text = ok and (_("Connected to ") .. tostring(detail) .. "\n\n"
          .. _("Sync will keep your notes up to date."))
        or (_("Saved, but Obsidian did not answer:") .. "\n\n" .. tostring(detail)
          .. "\n\n" .. _("Check that Obsidian is running with the Local REST API plugin enabled.")),
      timeout = ok and 5 or 10,
    })
  end)
end

-- Two fields in one dialog when this KOReader has the widget for it, two dialogs
-- in a row when it does not — the address is useless without the key, so asking
-- for them separately still has to end in the same place.
local function askForApiKey(address, on_change)
  local dialog
  dialog = InputDialog:new{
    title = _("Obsidian API key"),
    description = _("Copy it from Obsidian: Settings → Local REST API."),
    input = Obsidian.getApiKey() or "",
    input_type = "text",
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function() UIManager:close(dialog) end,
        },
        {
          text = _("Save"),
          is_enter_default = true,
          callback = function()
            local key = dialog:getInputText()
            UIManager:close(dialog)
            saveObsidianServer(address, key, on_change)
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
  dialog:onShowKeyboard()
end

local function showObsidianServerDialog(on_change)
  local ok, MultiInputDialog = pcall(require, "ui/widget/multiinputdialog")
  if ok and MultiInputDialog then
    local dialog
    local shown = pcall(function()
      dialog = MultiInputDialog:new{
        title = _("Connect to Obsidian"),
        fields = {
          {
            description = _("Address of the computer running Obsidian"),
            text = Obsidian.getServerUrl() or "",
            hint = "192.168.1.20:27124",
            input_type = "string",
          },
          {
            description = _("API key, from Settings → Local REST API"),
            text = Obsidian.getApiKey() or "",
            hint = _("64 characters"),
            input_type = "string",
          },
        },
        buttons = {
          {
            {
              text = _("Cancel"),
              id = "close",
              callback = function() UIManager:close(dialog) end,
            },
            {
              text = _("Save"),
              is_enter_default = true,
              callback = function()
                local fields = dialog:getFields()
                UIManager:close(dialog)
                saveObsidianServer(fields[1], fields[2], on_change)
              end,
            },
          },
        },
      }
      UIManager:show(dialog)
      dialog:onShowKeyboard()
    end)
    if shown then return end
  end

  local dialog
  dialog = InputDialog:new{
    title = _("Connect to Obsidian"),
    description = _("The address of the computer running Obsidian, e.g. 192.168.1.20:27124. It needs the Local REST API plugin, and has to be on the same network as this reader."),
    input = Obsidian.getServerUrl() or "",
    input_type = "text",
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function() UIManager:close(dialog) end,
        },
        {
          text = _("Next"),
          is_enter_default = true,
          callback = function()
            local address = dialog:getInputText()
            UIManager:close(dialog)
            if not address or address == "" then return end
            askForApiKey(address, on_change)
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
  dialog:onShowKeyboard()
end

-- KOReader's folder picker is much kinder than typing a path on e-ink, but the
-- dialog has to work without it too: the widget has moved between releases, and
-- a missing picker must not cost the user the ability to set a vault at all.
local function pathChooser()
  local ok, PathChooser = pcall(require, "ui/widget/pathchooser")
  if ok and PathChooser then return PathChooser end
  return nil
end

local function chooseVaultFolder(on_change)
  local PathChooser = pathChooser()
  if not PathChooser then return false end
  return (pcall(function()
    UIManager:show(PathChooser:new{
      title = _("Choose your Obsidian vault"),
      select_directory = true,
      select_file = false,
      path = Obsidian.getVaultPath() or require("datastorage"):getDataDir(),
      onConfirm = function(path)
        local vault, err = Obsidian.setVaultPath(path)
        reportVaultSet(vault, err, on_change)
      end,
    })
  end))
end

--- Where the vault is. Typing always works; a folder picker is offered on top
--- when this KOReader has one.
local function showObsidianVaultDialog(on_change)
  local dialog
  local row = {
    {
      text = _("Cancel"),
      callback = function() UIManager:close(dialog) end,
    },
    {
      text = _("Save"),
      is_enter_default = true,
      callback = function()
        local path = dialog:getInputText()
        UIManager:close(dialog)
        if not path or path == "" then return end
        local vault, err = Obsidian.setVaultPath(path)
        reportVaultSet(vault, err, on_change)
      end,
    },
  }

  if pathChooser() then
    table.insert(row, 2, {
      text = _("Browse…"),
      callback = function()
        UIManager:close(dialog)
        if not chooseVaultFolder(on_change) then
          showError(_("This KOReader has no folder picker; type the path instead."))
        end
      end,
    })
  end

  dialog = InputDialog:new{
    title = _("Obsidian vault folder"),
    description = _("The folder your vault lives in. Notes are written to a folder inside it, one per book."),
    input = Obsidian.getVaultPath() or "",
    input_type = "text",
    buttons = { row },
  }

  UIManager:show(dialog)
  dialog:onShowKeyboard()
end

return {
  explain = explainHighlight,
  translate = translateHighlight,
  isTranslationEnabled = isTranslationEnabled,
  showPairingDialog = showPairingDialog,
  showObsidianVaultDialog = showObsidianVaultDialog,
  showObsidianServerDialog = showObsidianServerDialog,
}
