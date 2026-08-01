-- Cover.extract has no dedicated coverage today (only exercised indirectly,
-- if at all, through sync's cover-transport tests). This drives it directly
-- against a fake blitbuffer-like image, matching only the calls
-- lunote_cover.lua actually makes: getWidth, getHeight, scale, writePNG, free.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local ko = dofile(here .. "/support.lua")
local check = ko.check

-- Mirrors lunote_cover.lua's own MAX_DIMENSION; not exported, so pinned here.
local MAX_DIMENSION = 400

-- Bytes encode the dimensions KOReader's PNG writer was actually called with, so a test
-- can tell whether scaling happened without reaching into module internals.
local function fakeImage(w, h, opts)
    opts = opts or {}
    local bb = { w = w, h = h, freed = false }
    function bb:getWidth() return self.w end
    function bb:getHeight() return self.h end
    function bb:scale(nw, nh)
        if opts.fail_scale then error("scale failed") end
        return fakeImage(nw, nh, opts)
    end
    function bb:free() self.freed = true end
    return bb
end

local function makeDocument(image)
    return { getCoverPageImage = function() return image end }
end

local TMP_PATH = ko.SCRATCH .. "/dbdir/lunote_cover_tmp.png"

print("cover extraction")

ko.reset()
ko.modules.device.screen.bb = {
    writePNG = function(_, path, _, image)
        local f = io.open(path, "wb")
        f:write(string.format("%dx%d", image.w, image.h))
        f:close()
    end,
}
local Cover = require("lunote_cover")

check("nil document returns nil, does not raise", Cover.extract(nil) == nil)

check("document with no cover returns nil",
    Cover.extract(makeDocument(nil)) == nil)

do
    local raising_document = { getCoverPageImage = function() error("boom") end }
    local ok, result = pcall(Cover.extract, raising_document)
    check("a raising getCoverPageImage is caught, not propagated", ok and result == nil, result)
end

do
    local bytes = Cover.extract(makeDocument(fakeImage(300, 200)))
    check("an in-bounds image is not scaled", bytes == "300x200", bytes)
end

do
    local image = fakeImage(800, 400)
    local bytes = Cover.extract(makeDocument(image))
    -- long side 800 -> scaled to MAX_DIMENSION, short side scaled proportionally
    local expected = string.format("%dx%d", MAX_DIMENSION, math.floor(400 * (MAX_DIMENSION / 800)))
    check("an oversized image is scaled to fit MAX_DIMENSION", bytes == expected, bytes)
end

do
    ko.modules.device.screen.bb.writePNG = function(_, path)
        local f = io.open(path, "wb")
        if f then f:write("partial"); f:close() end
        error("write failed")
    end
    local image = fakeImage(4000, 4000)
    local bytes = Cover.extract(makeDocument(image))
    check("a writePNG failure returns nil instead of raising", bytes == nil, bytes)
    local leftover = io.open(TMP_PATH, "rb")
    if leftover then leftover:close() end
    check("a writePNG failure leaves no temp file behind", leftover == nil)
end

ko.summary()
