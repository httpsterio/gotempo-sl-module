-- Logic tests for the strap picker, run outside the game under Lua 5.1 (the
-- version the engine uses). mkharness.py lifts the real function bodies out of
-- gotempo.lua, so these cannot drift from the source.

local fakeFile, today, nowSecs = nil, 20260912, 45000
DEVICES_FILE, DEVICES_MAX_AGE, SCAN_WAIT = "devices.txt", 90, 20
PROFILE_INI, PROFILE_SECTION, PROFILE_KEY = "gotempo.ini", "gotempo", "Device"
PROFILE_KEY_COLOR, PROFILE_KEY_THICKNESS = "Color", "Thickness"
PROFILE_SLOTS = { "ProfileSlot_Player1", "ProfileSlot_Player2" }
SIDES = { "PlayerNumber_P1", "PlayerNumber_P2" }
HR_THICKNESS_MAX = 4
HR_GRAPH_THICKNESS = 1.5
HR_GRAPH_COLOR = { 1, 0.31, 0.64, 1 }
HR_COLOR_CHOICES = { "#FF4FA3", "#F56C27", "#FFC24B", "#13BE74",
                     "#4DB8FF", "#B07CFF", "#FF5555", "#FFFFFF" }
HR_THICKNESS_CHOICES = { 0.6, 0.8, 1.0, 1.2, 1.4, 1.7, 2.0, 2.5 }

function todayStamp() return today end
function secondsOfDay() return nowSecs end
function color(hex) return { hex = hex } end

RageFileUtil = { CreateRageFile = function()
	return {
		Open = function(_, _, _) return fakeFile ~= nil end,
		Read = function() return fakeFile end,
		Close = function() end,
		destroy = function() end,
	}
end }

local profiles, written = {}, {}
PROFILEMAN = {
	GetNumLocalProfiles = function() return #profiles end,
	GetLocalProfileFromIndex = function(_, i) return { GetDisplayName = function() return profiles[i+1].name end } end,
	GetLocalProfileIDFromIndex = function(_, i) return tostring(i) end,
	LocalProfileIDToDir = function(_, id) return profiles[tonumber(id)+1].dir end,
	GetProfileDir = function(_, slot) return slot == PROFILE_SLOTS[1] and "/p1/" or "/p2/" end,
}
IniFile = {
	ReadFile = function(path)
		for _, p in ipairs(profiles) do
			if path == p.dir .. PROFILE_INI then return p.ini end
		end
		return written[path]
	end,
	WriteFile = function(path, contents) written[path] = contents end,
}

picker = { devices = {}, owners = {} }
side = {}

-- Stubs for the two branches that reach the radio or rebuild the list; the
-- tests care that Confirm routes to them, not what they then do.
local began, listed = 0, 0
function BeginScan(st) began = began + 1 end
function ShowList(st) listed = listed + 1 end

-- Beside this script, not beside the working directory: the Makefile, CI and a
-- hand run all start from different places.
local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
dofile(here .. "/extracted.lua")

local fails = 0
local function check(ok, msg)
	if not ok then fails = fails + 1; print("FAIL " .. msg) else print("ok   " .. msg) end
end
local function group(name) print(""); print("── " .. name) end

-- ── ReadDevices ─────────────────────────────────────────────────────────────
group("gotempo's device list")

fakeFile = "20260912 44990\n24:AC:AC:18:41:CC\tPolar H10\n11:22:33:44:55:66\tHRM-Dual\n"
local d = ReadDevices()
check(d ~= nil and #d == 2, "a fresh list parses")
check(d and d[1].mac == "24:AC:AC:18:41:CC" and d[1].name == "Polar H10", "mac and name split on the tab")

fakeFile = "20260912 44990\nAA:BB:CC:DD:EE:FF\t\n"
check(ReadDevices()[1].name == "AA:BB:CC:DD:EE:FF", "a nameless strap falls back to its mac")

fakeFile = "20260911 44990\n24:AC:AC:18:41:CC\tPolar\n"
check(ReadDevices() == nil, "yesterday's list is rejected")
fakeFile = "20260912 44000\n24:AC:AC:18:41:CC\tPolar\n"
check(ReadDevices() == nil, "a list older than DEVICES_MAX_AGE is rejected")
fakeFile = ""
check(ReadDevices() == nil, "an expired (blanked) list reads as nothing")
fakeFile = nil
check(ReadDevices() == nil, "a missing file reads as nothing")
fakeFile = "not a stamp\n24:AC\tPolar\n"
check(ReadDevices() == nil, "a malformed stamp is rejected")

-- ── StrapOwners ─────────────────────────────────────────────────────────────
group("who already claims what")

profiles = {
	{ dir = "/a/", name = "http",    ini = { gotempo = { Device = "24:ac:ac:18:41:cc" } } },
	{ dir = "/b/", name = "Sami KB", ini = { gotempo = { Device = "24:AC:AC:18:41:CC" } } },
	{ dir = "/c/", name = "mira",    ini = { gotempo = { Device = "11:22:33:44:55:66" } } },
	{ dir = "/d/", name = "guest",   ini = {} },
}
local owners = StrapOwners()
check(#owners["24:AC:AC:18:41:CC"] == 2, "a shared strap lists both owners, whatever the mac case")
check(#owners["11:22:33:44:55:66"] == 1, "a sole owner is listed")

-- ── PickerRows ──────────────────────────────────────────────────────────────
group("how the list is ordered")

local devices = {
	{ mac = "24:AC:AC:18:41:CC", name = "Polar H10 1841" },
	{ mac = "11:22:33:44:55:66", name = "HRM-Dual" },
	{ mac = "99:88:77:66:55:44", name = "Alpha strap" },
}
local rows = PickerRows(devices, owners, nil)
check(rows[1].name == "Alpha strap", "unclaimed straps come first")
check(rows[2].divider == true, "a divider separates claimed from free")
check(rows[3].name == "HRM-Dual" and rows[4].name == "Polar H10 1841", "claimed group is alphabetical")
check(rows[3].owners ~= nil and rows[1].owners == nil, "only claimed rows carry owners")

-- Your own strap is not "in use by others" just because your profile claims it.
local mine = PickerRows(devices, owners, "24:ac:ac:18:41:cc")
check(mine[1].name == "Polar H10 1841" and mine[1].yours == true, "your strap is first and marked")
check(mine[1].owners == nil, "your own name is not listed against it")
check(mine[2].name == "Alpha strap", "free straps still follow")

check(#PickerRows({ { mac = "01:02:03:04:05:06", name = "Solo" } }, {}, nil) == 1,
	"no divider when nothing is claimed")
check(#PickerRows({ { mac = "11:22:33:44:55:66", name = "HRM-Dual" } }, owners, nil) == 1,
	"no divider when nothing is free")

-- ── the per-side menu ───────────────────────────────────────────────────────
group("what a side offers")

local function newSide(pn, device)
	return { pn = pn, profile = true, cursor = 1, first = 1, dirty = false,
	         device = device, color = 1, thickness = 3 }
end

local st = newSide(1, "24:AC:AC:18:41:CC")
ShowNav(st)
check(st.rows[1].name == "Change strap", "a side with a strap offers Change")
check(st.rows[2].action == "remove", "and Remove")
check(st.rows[#st.rows].name == "Exit", "with nothing changed, leaving is just Exit")

local function kinds(rows)
	local out = {}
	for _, row in ipairs(rows) do out[#out+1] = row.adjust or row.action end
	return table.concat(out, ",")
end
check(kinds(st.rows) == "choose,remove,color,thickness,save,exit",
	"the whole menu, in order")

local bare = newSide(2, nil)
ShowNav(bare)
check(bare.rows[1].name == "Choose a strap", "a side without one offers Choose")
check(kinds(bare.rows) == "choose,color,thickness,save,exit", "with no Remove to offer")

-- Every side is built from its own state, so one holding a strap and the other
-- not can never show each other's menu.
check(st.rows[1].name ~= bare.rows[1].name, "the two sides differ independently")

-- ── pending changes ─────────────────────────────────────────────────────────
group("changes are held until Save")

st = newSide(1, "24:AC:AC:18:41:CC")
ShowNav(st)
st.cursor = 2                   -- Remove strap
Confirm(st)
check(st.device == nil, "Remove clears the strap")
check(st.dirty == true, "and marks the side unsaved")
check(st.rows[#st.rows].name == "Back without saving", "the exit row now warns")
check(written["/p1/gotempo.ini"] == nil, "nothing has been written yet")

-- ── Save ────────────────────────────────────────────────────────────────────
group("Save commits, and only then")

written = {}
profiles = {}
written["/p1/gotempo.ini"] = { gotempo = { Device = "OLD", Other = "keep me" } }
st = newSide(1, "11:22:33:44:55:66")
st.color, st.thickness = 2, 5
SaveSide(st)
local ini = written["/p1/gotempo.ini"].gotempo
check(ini.Device == "11:22:33:44:55:66", "the chosen strap is written")
check(ini.Color == "#F56C27", "the chosen colour is written")
check(ini.Thickness == 1.4, "the chosen thickness is written")
check(ini.Other == "keep me", "keys this module does not own survive")
check(st.finished == "saved", "the side is finished")
check(st.dirty == false, "and no longer unsaved")

written = {}
st = newSide(2, nil)
SaveSide(st)
check(written["/p2/gotempo.ini"].gotempo.Device == nil, "saving no strap removes the key")

-- ── closing ─────────────────────────────────────────────────────────────────
group("the menu closes only when everyone is done")

side = { [1] = newSide(1, nil), [2] = newSide(2, nil) }
check(PickerAllDone() == false, "two sides, neither finished")
FinishSide(side[1], "saved")
check(PickerAllDone() == false, "one finished is not enough")
FinishSide(side[2], "exited")
check(PickerAllDone() == true, "both finished closes it")

-- A side with no profile has nowhere to save, so it must not hold the menu open.
side = { [1] = newSide(1, nil), [2] = { pn = 2, profile = false, finished = "noprofile" } }
FinishSide(side[1], "saved")
check(PickerAllDone() == true, "a profileless side never blocks the close")

-- ── cursor ──────────────────────────────────────────────────────────────────
group("cursor")

st = { rows = PickerRows(devices, owners, nil), cursor = 1 }
Move(st, 1)
check(st.cursor == 3, "moving down steps over the divider")
Move(st, -1)
check(st.cursor == 1, "moving up steps back over it")
st.cursor = #st.rows
Move(st, 1)
check(st.cursor == 1, "the cursor wraps")

-- ── appearance values ───────────────────────────────────────────────────────
group("colour and thickness")

check(ParseThickness(1.4) == 1.4, "a numeric Thickness from IniFile parses")
check(ParseThickness("1.4") == 1.4, "a string Thickness parses")
check(ParseThickness(0) == nil and ParseThickness(-1) == nil, "non-positive is rejected")
check(ParseThickness(500) == nil, "a runaway value is rejected")
check(NormalizeHex("F56C27") == "#F56C27", "a bare hex gains its hash")
check(NormalizeHex("#FFF") == nil and NormalizeHex("pink") == nil, "junk is rejected")

profiles = { { dir = "/p1/", name = "x", ini = { gotempo = { Thickness = 1.4, Color = "#F56C27" } } } }
PROFILEMAN.GetProfileDir = function(_, _) return "/p1/" end
local style = ProfileStyle(1)
check(style.thickness == 1.5 * 1.4, "Thickness multiplies the configured width")
check(style.colorHex == "#F56C27", "the hex is kept so the picker can show the preset")

-- Read fresh every call. It used to be cached against the profile directory,
-- which does not change when the picker rewrites that directory's ini -- so a
-- saved thickness was ignored for the rest of the session.
profiles[1].ini.gotempo.Thickness = 0.6
check(ProfileStyle(1).thickness == 1.5 * 0.6, "a saved change is picked up without a restart")
profiles[1].ini.gotempo.Color = "#13BE74"
check(ProfileStyle(1).colorHex == "#13BE74", "and so is a saved colour")

profiles[1].ini.gotempo = { Device = "24:AC:AC:18:41:CC" }
local none = ProfileStyle(1)
check(none.thickness == 1.5 and none.colorHex == nil, "no settings falls back to the defaults")

print("")
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
