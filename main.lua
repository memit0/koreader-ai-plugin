local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

local Dialogs = require("dialogs")
local UpdateChecker = require("update_checker")

local AskGPT = InputContainer:new {
  name = "askgpt",
  is_doc_only = true,
}

-- Flag to ensure the update message is shown only once per session
local updateMessageShown = false

local function checkForUpdatesOnce()
  if updateMessageShown then return end
  updateMessageShown = true -- Set flag to true so it won't show again
  -- A failed update check must never take the reader down with it
  pcall(UpdateChecker.checkForUpdates)
end

-- Grabs the selection, dismisses the highlight menu (keeping the highlight
-- itself), and runs `action` once we have a network connection.
function AskGPT:runOnHighlight(reader_highlight, action)
  local highlighted_text = reader_highlight.selected_text and reader_highlight.selected_text.text
  reader_highlight:onClose(true)
  if not highlighted_text or highlighted_text == "" then return end

  NetworkMgr:runWhenOnline(function()
    checkForUpdatesOnce()
    action(self.ui, highlighted_text)
  end)
end

function AskGPT:init()
  self.ui.highlight:addToHighlightDialog("askgpt_01_explain", function(reader_highlight)
    return {
      text = _("Explain"),
      callback = function()
        self:runOnHighlight(reader_highlight, Dialogs.explain)
      end,
    }
  end)

  if Dialogs.isTranslationEnabled() then
    self.ui.highlight:addToHighlightDialog("askgpt_02_translate", function(reader_highlight)
      return {
        text = _("AI Translate"),
        callback = function()
          self:runOnHighlight(reader_highlight, Dialogs.translate)
        end,
      }
    end)
  end
end

return AskGPT
