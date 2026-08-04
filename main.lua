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
        -- One Sync, to wherever this device is set up to send: the web app, the
        -- Obsidian vault, or both.
        text_func = function()
          local outstanding = Sync.countOutstanding()
          if outstanding == 0 then return _("Sync now") end
          return string.format("%s (%d)", _("Sync now"), outstanding)
        end,
        enabled_func = function() return Sync.hasDestination() end,
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
      -- The usual case: Obsidian is running on a computer or phone on the same
      -- network, with the Local REST API plugin listening.
      text_func = function()
        local server = Obsidian.getServerUrl()
        if not server then return _("Connect to Obsidian…") end
        return _("Obsidian: ") .. server:gsub("^https?://", "")
      end,
      keep_menu_open = true,
      callback = function(touchmenu_instance)
        Dialogs.showObsidianServerDialog(function() refresh(touchmenu_instance) end)
      end,
    },
    {
      text = _("Test the connection"),
      enabled_func = function() return Obsidian.isServerConfigured() end,
      keep_menu_open = true,
      callback = function()
        NetworkMgr:runWhenOnline(function()
          local ok, detail = Obsidian.testConnection()
          UIManager:show(InfoMessage:new{
            text = ok and (_("Connected to ") .. tostring(detail))
              or (_("Could not connect:") .. "\n\n" .. tostring(detail)),
            timeout = ok and 5 or 10,
          })
        end)
      end,
    },
    {
      -- For a vault that lives on the device itself, or a folder something else
      -- syncs. Works with no network at all.
      text_func = function()
        local vault = Obsidian.getVaultPath()
        if not vault then return _("Write to a folder instead…") end
        -- The end of a long path says more than its beginning
        if #vault > 34 then vault = "…" .. vault:sub(-33) end
        return _("Folder: ") .. vault
      end,
      keep_menu_open = true,
      separator = true,
      callback = function(touchmenu_instance)
        Dialogs.showObsidianVaultDialog(function() refresh(touchmenu_instance) end)
      end,
    },
    {
      text_func = function()
        local pending = Obsidian.countPending()
        if pending == 0 then return _("Write notes now") end
        return string.format("%s (%d)", _("Write notes now"), pending)
      end,
      enabled_func = function() return Obsidian.isConfigured() end,
      keep_menu_open = true,
      callback = function(touchmenu_instance)
        NetworkMgr:runWhenOnline(function() Obsidian.runInteractive() end)
        refresh(touchmenu_instance)
      end,
    },
    {
      -- Only the folder destination writes on close; sending over the network is
      -- left to Sync, because closing a book is no moment to wait on wifi.
      text = _("Write to the folder when a book is closed"),
      checked_func = function() return Obsidian.isAutoExportEnabled() end,
      enabled_func = function() return Obsidian.getVaultPath() ~= nil end,
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
        NetworkMgr:runWhenOnline(function() Obsidian.rewriteEverything() end)
        refresh(touchmenu_instance)
      end,
    },
    {
      text = _("Disconnect from Obsidian"),
      enabled_func = function() return Obsidian.isConfigured() end,
      keep_menu_open = true,
      callback = function(touchmenu_instance)
        Obsidian.forgetServer()
        Obsidian.forgetVault()
        UIManager:show(InfoMessage:new{
          text = _("Disconnected. The notes already in your vault stay where they are."),
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
