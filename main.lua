local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local Dialogs = require("lunote_dialogs")
local Annotations = require("lunote_annotations")
local History = require("lunote_history")
local HistoryBrowser = require("lunote_history_browser")
local Obsidian = require("lunote_obsidian")
local Sync = require("lunote_sync")
local UpdateChecker = require("lunote_update_checker")

-- Not is_doc_only: the history browser has to work from the file manager too,
-- where there is no document open. Anything reader-specific is guarded below.
local Lunote = InputContainer:new {
  name = "lunote",
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
function Lunote:runOnHighlight(reader_highlight, index, action)
  local highlighted_text = reader_highlight.selected_text and reader_highlight.selected_text.text
  reader_highlight:onClose(true)
  if not highlighted_text or highlighted_text == "" then return end

  NetworkMgr:runWhenOnline(function()
    checkForUpdatesOnce()
    action(self.ui, highlighted_text, index)
  end)
end

function Lunote:init()
  -- Absent in the file manager, where there is nothing to highlight
  if self.ui.highlight then
    self.ui.highlight:addToHighlightDialog("lunote_01_explain", function(reader_highlight, index)
      return {
        text = _("Explain"),
        callback = function()
          self:runOnHighlight(reader_highlight, index, Dialogs.explain)
        end,
      }
    end)

    if Dialogs.isTranslationEnabled() then
      self.ui.highlight:addToHighlightDialog("lunote_02_translate", function(reader_highlight, index)
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
--- document is still open, so syncing never has to walk sidecars. The book's
--- Obsidian note is rewritten from that snapshot, which is why closing a book is
--- all it takes to keep a vault current.
function Lunote:onCloseDocument()
  Obsidian.exportOnClose(Annotations.mirror(self.ui))
end

function Lunote:addToMainMenu(menu_items)
  menu_items.lunote = {
    text = _("Lunote"),
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
            Dialogs.showPairingDialog()
          end
          if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
      },
      {
        text = _("Obsidian vault"),
        sub_item_table = self:obsidianMenu(),
      },
    },
  }
end

-- A vault is a folder of markdown files, so this whole submenu is about one
-- path and when to write to it.
function Lunote:obsidianMenu()
  local function refresh(touchmenu_instance)
    if touchmenu_instance then touchmenu_instance:updateItems() end
  end

  return {
    {
      text_func = function()
        local vault = Obsidian.getVaultPath()
        if not vault then return _("Set vault folder…") end
        -- The end of a long path says more than its beginning
        if #vault > 40 then vault = "…" .. vault:sub(-39) end
        return _("Vault: ") .. vault
      end,
      keep_menu_open = true,
      callback = function(touchmenu_instance)
        Dialogs.showObsidianVaultDialog(function() refresh(touchmenu_instance) end)
      end,
    },
    {
      text_func = function()
        local pending = Obsidian.countPending()
        if pending == 0 then return _("Write notes to vault") end
        return string.format("%s (%d)", _("Write notes to vault"), pending)
      end,
      enabled_func = function() return Obsidian.isConfigured() end,
      keep_menu_open = true,
      callback = function(touchmenu_instance)
        Obsidian.runInteractive()
        refresh(touchmenu_instance)
      end,
    },
    {
      text = _("Write when a book is closed"),
      checked_func = function() return Obsidian.isAutoExportEnabled() end,
      enabled_func = function() return Obsidian.isConfigured() end,
      keep_menu_open = true,
      callback = function(touchmenu_instance)
        Obsidian.setAutoExport(not Obsidian.isAutoExportEnabled())
        refresh(touchmenu_instance)
      end,
    },
    {
      text = _("Rewrite every note"),
      enabled_func = function() return Obsidian.isConfigured() end,
      keep_menu_open = true,
      separator = true,
      callback = function(touchmenu_instance)
        Obsidian.rewriteEverything()
        refresh(touchmenu_instance)
      end,
    },
    {
      text = _("Forget vault folder"),
      enabled_func = function() return Obsidian.isConfigured() end,
      keep_menu_open = true,
      callback = function(touchmenu_instance)
        Obsidian.forgetVault()
        UIManager:show(InfoMessage:new{
          text = _("Vault folder forgotten. The notes already written stay where they are."),
          timeout = 5,
        })
        refresh(touchmenu_instance)
      end,
    },
  }
end

--- Called by PluginLoader's "Disable plugin and delete settings".
function Lunote:deletePluginSettings()
  History.deleteDatabase()
end

return Lunote
