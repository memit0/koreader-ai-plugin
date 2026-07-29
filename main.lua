local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local Dialogs = require("dialogs")
local Annotations = require("annotations")
local History = require("history")
local HistoryBrowser = require("history_browser")
local Sync = require("sync")
local UpdateChecker = require("update_checker")

-- Not is_doc_only: the history browser has to work from the file manager too,
-- where there is no document open. Anything reader-specific is guarded below.
local AskGPT = InputContainer:new {
  name = "askgpt",
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
function AskGPT:runOnHighlight(reader_highlight, index, action)
  local highlighted_text = reader_highlight.selected_text and reader_highlight.selected_text.text
  reader_highlight:onClose(true)
  if not highlighted_text or highlighted_text == "" then return end

  NetworkMgr:runWhenOnline(function()
    checkForUpdatesOnce()
    action(self.ui, highlighted_text, index)
  end)
end

function AskGPT:init()
  -- Absent in the file manager, where there is nothing to highlight
  if self.ui.highlight then
    self.ui.highlight:addToHighlightDialog("askgpt_01_explain", function(reader_highlight, index)
      return {
        text = _("Explain"),
        callback = function()
          self:runOnHighlight(reader_highlight, index, Dialogs.explain)
        end,
      }
    end)

    if Dialogs.isTranslationEnabled() then
      self.ui.highlight:addToHighlightDialog("askgpt_02_translate", function(reader_highlight, index)
        return {
          text = _("AI Translate"),
          callback = function()
            self:runOnHighlight(reader_highlight, index, Dialogs.translate)
          end,
        }
      end)
    end
  end

  if self.ui.menu then
    self.ui.menu:registerToMainMenu(self)
  end
end

--- Snapshot this book's highlights and notes into the local store while the
--- document is still open, so syncing never has to walk sidecars.
function AskGPT:onCloseDocument()
  Annotations.mirror(self.ui)
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

function AskGPT:addToMainMenu(menu_items)
  menu_items.askgpt = {
    text = _("AskGPT"),
    sub_item_table = {
      {
        text = _("Browse saved explanations"),
        keep_menu_open = false,
        callback = function() HistoryBrowser.show() end,
      },
      {
        text_func = function()
          local outstanding = History.countDirty() or 0
          if outstanding == 0 then return _("Sync to web app") end
          return string.format("%s (%d)", _("Sync to web app"), outstanding)
        end,
        enabled_func = function() return Sync.isConfigured() end,
        keep_menu_open = true,
        callback = function()
          NetworkMgr:runWhenOnline(function() Sync.runInteractive() end)
        end,
      },
      {
        text_func = function()
          return Sync.isConfigured() and _("Unpair from web app") or _("Pair with web app")
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
          if Sync.isConfigured() then
            Sync.unpair()
            UIManager:show(InfoMessage:new{ text = _("Unpaired."), timeout = 3 })
          else
            showPairingDialog()
          end
          if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
      },
    },
  }
end

--- Called by PluginLoader's "Disable plugin and delete settings".
function AskGPT:deletePluginSettings()
  History.deleteDatabase()
end

return AskGPT
