--[[--
Writes an explanation into the book's own KOReader annotation, so it shows up in
Bookmarks beside your highlights and your own notes, and is picked up by the
built-in Exporter.

We deliberately do not call `ui.highlight:editNote()`. That routes to
ReaderBookmark:setBookmarkNote, which opens an InputDialog for confirmation — fine
for the built-in Translator's "Save to note" button, but it would put a dialog back
in front of a one-tap Explain. We mirror its append semantics and write the
annotation directly instead.
]]
local Event = require("ui/event")
local History = require("history")
local logger = require("logger")

local Annotations = {}

--- Book identity for the open document: the same (title, authors, md5) triple
--- KOReader's own Statistics plugin uses, so history survives a rename or move.
function Annotations.getBook(ui)
    local props = ui.document and ui.document:getProps() or {}
    local file = ui.document and ui.document.file
    local md5
    if file then
        local util = require("util")
        local ok, result = pcall(util.partialMD5, file)
        if ok then md5 = result end
    end
    return {
        title = props.title or "",
        authors = props.authors or "",
        md5 = md5 or "",
        file = file or "",
    }
end

--- Saves `explanation` onto the annotation for the current selection.
--- `index` is the annotation index when the user long-pressed an existing
--- highlight, and nil for a fresh selection.
--- Returns { datetime, chapter, pageno } — datetime being the annotation's
--- stable id within the book — or nil if there was nothing to attach to.
function Annotations.saveToBook(ui, index, explanation)
    local ok, result = pcall(function()
        if not (ui and ui.highlight and ui.annotation) then return nil end

        if not index then
            -- Fresh selection: turn it into a real highlight so the note has
            -- something to hang off. Returns nil if the selection has no
            -- positions (e.g. an OCR selection in a scanned PDF).
            index = ui.highlight:saveHighlight()
            if not index then return nil end
        end

        local annotation = ui.annotation.annotations[index]
        if not annotation then return nil end

        -- Same "\n\n" append the note editor uses; never clobber the user's text.
        -- With no note of their own there is nothing to separate from, so the
        -- label goes first without the blank lines. Both forms are recognised by
        -- History.stripAiNote, which is what keeps the explanation from syncing
        -- as if the reader had written it.
        if annotation.note and annotation.note ~= "" then
            annotation.note = annotation.note .. History.AI_NOTE_SEPARATOR .. explanation
        else
            annotation.note = History.AI_NOTE_MARKER .. "\n" .. explanation
        end
        annotation.note_format = "md"

        ui:handleEvent(Event:new("AnnotationsModified", { annotation }))
        return {
            datetime = annotation.datetime,
            chapter = annotation.chapter,
            pageno = annotation.pageno,
        }
    end)

    if not ok then
        logger.warn("AskGPT annotations:", tostring(result))
        return nil
    end
    return result
end

--- Snapshots the open book's annotations into the local store. Called when the
--- document closes so that syncing never has to walk sidecars or open documents.
function Annotations.mirror(ui)
    local ok, err = pcall(function()
        if not (ui and ui.annotation and ui.annotation.annotations) then return end
        History.mirrorAnnotations(Annotations.getBook(ui), ui.annotation.annotations)
    end)
    if not ok then logger.warn("AskGPT annotations:", tostring(err)) end
end

return Annotations
