local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local ko = dofile(here .. "/support.lua")
local check = ko.check

ko.reset()
local isNewer = require("lunote_update_checker").isNewer

check("1.10 is newer than 1.9", isNewer("v1.10.0", "1.9.0"))
check("patch release is newer", isNewer("v1.1.1", "1.1.0"))
check("equal versions are current", not isNewer("v1.1.0", "1.1.0"))
check("older version is current", not isNewer("v1.0.9", "1.1.0"))
check("invalid tags are ignored", not isNewer("latest", "1.1.0"))

ko.summary()
