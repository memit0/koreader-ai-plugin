-- lunote_history_browser.lua has no dedicated coverage today. This drives its
-- delete flow: Menu item -> hold_callback -> ConfirmBox -> ok_callback must
-- actually call History.deleteConversation, since that path is destructive.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local ko = dofile(here .. "/support.lua")
local check = ko.check

local BOOK = { title = "Book", authors = "Author", md5 = "abc", file = "/b.epub" }

print("history browser")
ko.reset()
local History = require("lunote_history")
local HistoryBrowser = require("lunote_history_browser")

History.startConversation{
    book = BOOK, kind = "explain", highlight = "a highlight",
    messages = { { role = "user", content = "q" }, { role = "assistant", content = "a" } },
}

HistoryBrowser.show()
local books_menu = ko.shown[#ko.shown]
check("book list shown", books_menu ~= nil and books_menu.item_table ~= nil)
check("one book listed", books_menu and #books_menu.item_table == 1)

books_menu.item_table[1].callback()
local conversations_menu = ko.shown[#ko.shown]
check("conversation list shown",
    conversations_menu ~= nil and #conversations_menu.item_table == 1)

conversations_menu.item_table[1].hold_callback()
local confirm = ko.shown[#ko.shown]
check("delete confirmation shown", confirm ~= nil and confirm.ok_callback ~= nil)

confirm.ok_callback()

local books = History.listBooks()
check("book still present", books ~= nil and #books == 1)
check("conversation deleted", books and #History.listConversations(books[1].id) == 0)

-- Regression: the book-list loop used to shadow gettext's `_` with its own
-- discarded loop variable, so this "Unknown Title" fallback crashed instead
-- of rendering, but only for a book with no title.
print("\nbook with no title")
ko.reset()
History = require("lunote_history")
HistoryBrowser = require("lunote_history_browser")
History.startConversation{
    book = { title = "", authors = "Author", md5 = "xyz", file = "/x.epub" },
    kind = "explain", highlight = "h",
    messages = { { role = "user", content = "q" }, { role = "assistant", content = "a" } },
}
local shown_ok, shown_err = pcall(HistoryBrowser.show)
check("untitled book renders without raising", shown_ok, shown_err)
local untitled_menu = ko.shown[#ko.shown]
check("falls back to Unknown Title", untitled_menu and untitled_menu.item_table[1].text:find("Unknown Title", 1, true) ~= nil,
    untitled_menu and untitled_menu.item_table[1].text)

ko.summary()
