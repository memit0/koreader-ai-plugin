--[[--
Extracts a book's cover as PNG bytes, for the sync payload.

KOReader documents decode their cover on demand (`document:getCoverPageImage()`)
rather than keeping one around, so this runs at document-close time, once per book
(see History.needsCoverExtraction). Never raises: sync should work fine for a book
with no extractable cover.
]]
local DataStorage = require("datastorage")
local Device = require("device")
local logger = require("logger")

local Cover = {}

-- Long side, in px. Covers are for a dashboard thumbnail, not a reader page.
local MAX_DIMENSION = 400

local TMP_PATH = DataStorage:getSettingsDir() .. "/lunote_cover_tmp.png"

--- Returns raw PNG bytes for `document`'s cover, or nil if it has none.
function Cover.extract(document)
    if not document then return nil end

    local ok, bb = pcall(function() return document:getCoverPageImage() end)
    if not ok or not bb then return nil end

    local w, h = bb:getWidth(), bb:getHeight()
    if w <= 0 or h <= 0 then return nil end

    local scaled
    if w > MAX_DIMENSION or h > MAX_DIMENSION then
        local scale = MAX_DIMENSION / math.max(w, h)
        local ok_scale, result = pcall(function()
            return bb:scale(math.floor(w * scale), math.floor(h * scale))
        end)
        if ok_scale then scaled = result end
    end
    local source = scaled or bb

    -- getCoverPageImage returns a blitbuffer; KOReader's framebuffer owns the
    -- PNG encoder and accepts the source buffer as its third argument.
    local ok_write, write_err = pcall(function()
        Device.screen.bb:writePNG(TMP_PATH, false, source)
    end)
    if scaled then scaled:free() end
    if not ok_write then
        os.remove(TMP_PATH)
        logger.warn("Lunote cover: could not encode PNG:", tostring(write_err))
        return nil
    end

    local file = io.open(TMP_PATH, "rb")
    if not file then return nil end
    local bytes = file:read("*a")
    file:close()
    os.remove(TMP_PATH)

    if not bytes or #bytes == 0 then return nil end
    return bytes
end

return Cover
