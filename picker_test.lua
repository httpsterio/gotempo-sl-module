-- Logic tests for the strap picker, run outside the game under Lua 5.1 (the
-- version the engine uses). mkharness.py lifts the real function bodies out of
-- gotempo.lua, so these cannot drift from the source.

local fakeFile, today, nowSecs = nil, 20260912, 45000
DEVICES_FILE, DEVICES_MAX_AGE, SCAN_WAIT = "devices.txt", 90, 20
PROFILE_INI, PROFILE_SECTION, PROFILE_KEY = "gotempo.ini", "gotempo", "Device"
PROFILE_KEY_COLOR, PROFILE_KEY_THICKNESS = "Color", "Thickness"
PROFILE_SLOTS = { "ProfileSlot_Player1", "ProfileSlot_Player2" }
SIDES = { "PlayerNumber_P1", "PlayerNumber_P2" }
HR_THICKNESS_MIN, HR_THICKNESS_MAX = 0.1, 4
HR_GRAPH_THICKNESS = 1.5
HR_DEFAULT_COLOR = "#FF5555"
HR_GRAPH_COLOR = { hex = HR_DEFAULT_COLOR }
-- Deliberately not the shipping order, and red deliberately not first: the
-- default must be found by hex, never by position.
HR_COLOR_CHOICES = {
	{ name = "pink",  hex = "#FF4FA3" },
	{ name = "coral", hex = "#E5633E" },
	{ name = "red",   hex = "#FF5555" },
	{ name = "light", hex = "#F3F3F3" },
}
HR_THICKNESS_CHOICES = {}
for i = 1, 40 do HR_THICKNESS_CHOICES[i] = i / 10 end

function todayStamp() return today end
function secondsOfDay() return nowSecs end
SCAN_ACK_WAIT, SCAN_WAIT = 6, 45
local uptime = 0
function GetTimeSinceStart() return uptime end
function CancelScan() end
function color(hex) return { hex = hex } end

local lastWrite = nil
RageFileUtil = { CreateRageFile = function()
	return {
		Open = function(_, _, mode) return mode == 2 or fakeFile ~= nil end,
		Read = function() return fakeFile end,
		Write = function(_, text) lastWrite = text end,
		Close = function() end,
		destroy = function() end,
	}
end }
local joined = { true, false }
GAMESTATE = { IsSideJoined = function(_, side) return joined[side == "PlayerNumber_P1" and 1 or 2] end }
function Year() return 2026 end
function MonthOfYear() return 8 end
function DayOfMonth() return 12 end
PLAYERS_FILE = "players.txt"
scanToken = nil

local profiles, written = {}, {}
PROFILEMAN = {
	GetNumLocalProfiles = function() return #profiles end,
	GetLocalProfileFromIndex = function(_, i) return { GetDisplayName = function() return profiles[i+1].name end } end,
	GetLocalProfileIDFromIndex = function(_, i) return tostring(i) end,
	LocalProfileIDToDir = function(_, id) return profiles[tonumber(id)+1].dir end,
	GetProfileDir = function(_, slot) return slot == PROFILE_SLOTS[1] and "/p1/" or "/p2/" end,
}
local iniReads = 0
IniFile = {
	ReadFile = function(path)
		iniReads = iniReads + 1
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
local status, d = ReadDevices()
check(status == "ready" and d ~= nil and #d == 2, "a fresh list parses")
check(d and d[1].mac == "24:AC:AC:18:41:CC" and d[1].name == "Polar H10", "mac and name split on the tab")

fakeFile = "20260912 44990\nAA:BB:CC:DD:EE:FF\t\n"
check(select(2, ReadDevices())[1].name == "AA:BB:CC:DD:EE:FF", "a nameless strap falls back to its mac")

fakeFile = "20260912 44990\n"
status, d = ReadDevices()
check(status == "ready" and #d == 0, "a list with no straps is an answer, not silence")

-- The acknowledgement.
fakeFile = "20260912 44995 scanning\n"
check(ReadDevices(44990) == "scanning", "a fresh acknowledgement reads as scanning")
fakeFile = "20260912 44995 something\n"
check(ReadDevices() == nil, "an unknown marker is not an answer")

-- The marker sits on the stamp line so a 2.0.0 module ignores the file. That
-- module accepts only this exact two-number pattern; checked literally here.
check(("20260912 44995 scanning"):match("^(%d+)%s+(%d+)$") == nil,
	"a 2.0.0 module's stamp pattern rejects the acknowledgement")

-- Anything stamped before the request belongs to an earlier one. Without this a
-- rescan returned the previous list at once.
fakeFile = "20260912 44980\n24:AC:AC:18:41:CC\tPolar H10\n"
check(ReadDevices(44990) == nil, "a list older than the request is not its answer")
check(ReadDevices(44980) == "ready", "a list from the request's own second is")
fakeFile = "20260912 44980 scanning\n"
check(ReadDevices(44990) == nil, "nor is an old acknowledgement")

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

-- ── waiting for gotempo ─────────────────────────────────────────────────────
group("waiting for gotempo")

local function scanFrom(askedAt, since)
	side = { [1] = { pn = 1, profile = true, mode = "scanning", rows = {} } }
	picker.scanning, picker.acked = true, false
	picker.askedAt, picker.since = askedAt, since
end

-- gotempo absent: nothing ever arrives.
scanFrom(100, 44990)
fakeFile = nil
uptime = 104; PickerPoll()
check(side[1].mode == "scanning", "still waiting inside the acknowledgement window")
uptime = 107; PickerPoll()
check(side[1].mode == "nogotempo", "no acknowledgement in time means gotempo is not running")

-- The case this fixes: acknowledged quickly, list arrives after twenty seconds.
scanFrom(100, 44990)
fakeFile = "20260912 44991 scanning\n"
uptime = 102; PickerPoll()
check(picker.acked, "the acknowledgement is noticed")
uptime = 121; PickerPoll()
check(side[1].mode == "scanning", "an acknowledged scan is still waited for past twenty seconds")
fakeFile = "20260912 45000\n24:AC:AC:18:41:CC\tPolar H10\n"
listed = 0
uptime = 122; PickerPoll()
check(listed == 1 and not picker.scanning, "and its list is accepted when it lands")

-- Acknowledged, then nothing: a stuck adapter, not a missing gotempo.
scanFrom(100, 44990)
fakeFile = "20260912 44991 scanning\n"
uptime = 102; PickerPoll()
uptime = 146; PickerPoll()
check(side[1].mode == "scantimeout", "a scan that never finishes says so, not that gotempo is gone")

-- An acknowledgement that has since been blanked is still remembered.
scanFrom(100, 44990)
fakeFile = "20260912 44991 scanning\n"
uptime = 102; PickerPoll()
fakeFile = ""
uptime = 110; PickerPoll()
check(side[1].mode == "scanning", "a blanked file after acknowledgement keeps waiting")

-- ── how often the profile ini is read ───────────────────────────────────────
group("reading profiles once, not every second")

do
	local savedProfiles, savedDir = profiles, PROFILEMAN.GetProfileDir
	local dirFor = { "/a/", "/b/" }
	PROFILEMAN.GetProfileDir = function(_, slot)
		return slot == PROFILE_SLOTS[1] and dirFor[1] or dirFor[2]
	end
	profiles = {
		{ dir = "/a/", name = "http", ini = { gotempo = { Device = "24:AC:AC:18:41:CC" } } },
		{ dir = "/c/", name = "other", ini = { gotempo = { Device = "11:22:33:44:55:66" } } },
	}

	ForgetProfileDevices()
	iniReads = 0
	check(ProfileDevice(1) == "24:AC:AC:18:41:CC", "the strap is read")
	for _ = 1, 10 do ProfileDevice(1) end
	check(iniReads == 1, "ten more ticks with the same profile do not touch the disk")

	-- Switch Profile on the song wheel: same slot, different folder.
	dirFor[1] = "/c/"
	check(ProfileDevice(1) == "11:22:33:44:55:66", "a different profile is noticed")
	check(iniReads == 2, "and read exactly once")

	-- A profile with no gotempo.ini is looked for once, not every second.
	dirFor[1] = "/nothing/"
	iniReads = 0
	check(ProfileDevice(1) == nil, "no ini means no strap")
	for _ = 1, 10 do ProfileDevice(1) end
	check(iniReads == 1, "a missing ini is not looked for again")

	-- The picker's Save changes the file but not the folder.
	dirFor[1] = "/a/"
	ProfileDevice(1)
	iniReads = 0
	RememberProfileDevice(1, "99:88:77:66:55:44")
	check(ProfileDevice(1) == "99:88:77:66:55:44", "a saved strap is published at once")
	check(iniReads == 0, "without reading the file back")

	-- Through Save itself, not just the helper: the picker must refresh the
	-- cache, or players.txt goes on naming the old strap until the next wheel.
	ProfileDevice(1)
	local saver = { pn = 1, profile = true, device = "AA:BB:CC:DD:EE:FF",
	                originalDevice = "99:88:77:66:55:44", touched = {}, rows = {} }
	SaveSide(saver)
	check(ProfileDevice(1) == "AA:BB:CC:DD:EE:FF", "saving in the picker publishes the new strap at once")
	-- Save wrote through the stub into P1's stored ini; put it back.
	profiles[1].ini.gotempo.Device = "24:AC:AC:18:41:CC"

	-- Entering the song wheel forgets, so a hand edit is picked up there.
	iniReads = 0
	ForgetProfileDevices()
	ProfileDevice(1)
	check(iniReads == 1, "forgetting forces one fresh read")

	-- During a song the lines are frozen: a tick only stamps the file.
	joined = { true, true }
	dirFor[2] = "/nothing/"
	ForgetProfileDevices()
	local frozen = PlayerLines()
	iniReads = 0
	for _ = 1, 5 do WritePlayers(frozen) end
	check(iniReads == 0, "ticks with frozen lines read no profile")
	check(lastWrite:find("p1 24:AC:AC:18:41:CC", 1, true) ~= nil, "and still publish P1's strap")
	check(lastWrite:find("p2 -", 1, true) ~= nil, "and P2 as joined with none")
	check(lastWrite:match("^20260912 %d+\n") ~= nil, "under a fresh stamp")

	-- Frozen means frozen: a side leaving mid-song does not change what is
	-- published, because nothing is looked up.
	joined = { true, false }
	WritePlayers(frozen)
	check(lastWrite:find("p2 -", 1, true) ~= nil, "frozen lines are published even if a lookup would differ")

	joined = { true, false }
	profiles, PROFILEMAN.GetProfileDir = savedProfiles, savedDir
	ForgetProfileDevices()
end

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
	         device = device, originalDevice = device, touched = {},
	         color = 1, colorHex = nil, thickness = 10 }
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
picker.colors = HR_COLOR_CHOICES

-- The bug this replaced: a player with hand-set values opens the menu only to
-- change strap, saves, and loses both.
written["/p1/gotempo.ini"] = { gotempo = {
	Device = "OLD", Color = "#123456", Thickness = 1.25, Other = "keep me" } }
st = newSide(1, "OLD")
st.device = "11:22:33:44:55:66"
SaveSide(st)
local ini = written["/p1/gotempo.ini"].gotempo
check(ini.Device == "11:22:33:44:55:66", "the chosen strap is written")
check(ini.Color == "#123456", "an untouched hand-set colour survives Save")
check(ini.Thickness == 1.25, "an untouched hand-set thickness survives Save")
check(ini.Other == "keep me", "keys this module does not own survive")
check(st.finished == "saved", "the side is finished")
check(st.dirty == false, "and no longer unsaved")

-- Touched settings are written.
written["/p1/gotempo.ini"] = { gotempo = { Color = "#123456", Thickness = 1.25 } }
st = newSide(1, nil)
ShowNav(st)
local colourRow, thickRow
for i, row in ipairs(st.rows) do
	if row.adjust == "color" then colourRow = i end
	if row.adjust == "thickness" then thickRow = i end
end
st.color = 1
Adjust(st, st.rows[colourRow], 1)
Adjust(st, st.rows[thickRow], 5)
SaveSide(st)
ini = written["/p1/gotempo.ini"].gotempo
check(ini.Color == "#E5633E", "a touched colour is written as hex")
check(math.abs(ini.Thickness - 1.5) < 1e-9, "a touched thickness is written")
check(ini.Device == nil, "an unchanged device is not written")

-- The file gained a strap after the menu opened (edited by hand, or by the other
-- side's save). A player who only touched their colour must not wipe it.
written["/p1/gotempo.ini"] = { gotempo = { Device = "24:AC:AC:18:41:CC" } }
st = newSide(1, nil)
ShowNav(st)
st.color = 1
Adjust(st, st.rows[colourRow], 1)
SaveSide(st)
check(written["/p1/gotempo.ini"].gotempo.Device == "24:AC:AC:18:41:CC",
	"a device the player did not change is left as the file has it")

-- Nothing changed, nothing rewritten.
written = {}
st = newSide(2, "24:AC:AC:18:41:CC")
SaveSide(st)
check(written["/p2/gotempo.ini"] == nil, "saving with no changes leaves the file alone")

-- Remove, then save.
written["/p2/gotempo.ini"] = { gotempo = { Device = "24:AC:AC:18:41:CC", Color = "#FF4FA3" } }
st = newSide(2, "24:AC:AC:18:41:CC")
st.device = nil
SaveSide(st)
check(written["/p2/gotempo.ini"].gotempo.Device == nil, "removing a strap removes the key")
check(written["/p2/gotempo.ini"].gotempo.Color == "#FF4FA3", "and leaves the colour alone")

-- Picking the strap you already had is not a change.
written = {}
st = newSide(1, "24:AC:AC:18:41:CC")
st.device = "24:ac:ac:18:41:cc"
SaveSide(st)
check(written["/p1/gotempo.ini"] == nil, "re-picking the same strap in other case is not a change")

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
check(ParseThickness(1.25) == 1.3, "a finer value rounds to a tenth")
check(ParseThickness(0.04) == 0.1, "a tiny positive value clamps up to 0.1")
check(ParseThickness(9) == 4, "a runaway value clamps down to 4")
check(ParseThickness(0) == nil and ParseThickness(-1) == nil, "non-positive is rejected")
check(ParseThickness("abc") == nil, "a non-number is rejected")

group("the colour list")

local function sidesWith(hex1, hex2)
	local a, b = newSide(1, nil), newSide(2, nil)
	a.colorHex, b.colorHex = hex1, hex2
	return { [1] = a, [2] = b }
end

local sides = sidesWith(nil, nil)
AssignColors(sides)
check(#picker.colors == #HR_COLOR_CHOICES, "no customs, just the palette")
check(picker.colors[sides[1].color].hex == HR_DEFAULT_COLOR,
	"no colour set starts on the default, found by hex not position")

sides = sidesWith("#123456", nil)
AssignColors(sides)
local last = picker.colors[#picker.colors]
check(last.hex == "#123456" and last.name == "P1 custom", "a hand-set colour joins the list as P1 custom")
check(picker.colors[sides[1].color].hex == "#123456", "P1 starts on their own custom colour")
check(ColorIndex(picker.colors, "#123456") ~= nil, "and P2 can step to it too")

sides = sidesWith("#123456", "#123456")
AssignColors(sides)
check(#picker.colors == #HR_COLOR_CHOICES + 1, "a colour both sides share appears once")
check(picker.colors[#picker.colors].name == "P1 custom", "named after the first side")

sides = sidesWith(nil, "#abcdef")
AssignColors(sides)
check(picker.colors[#picker.colors].name == "P2 custom", "a P2-only custom is named for P2")

sides = sidesWith("#ff4fa3", nil)
AssignColors(sides)
check(#picker.colors == #HR_COLOR_CHOICES, "a custom matching a preset adds nothing")
check(picker.colors[sides[1].color].name == "pink", "and shows the preset's name")

-- Stepping away from a custom colour must not remove it for the session.
sides = sidesWith("#123456", nil)
AssignColors(sides)
st = sides[1]
ShowNav(st)
for i, row in ipairs(st.rows) do if row.adjust == "color" then colourRow = i end end
Adjust(st, st.rows[colourRow], 1)
check(ColorIndex(picker.colors, "#123456") ~= nil, "stepping away keeps the custom colour on offer")

group("wrapping")

st.color = #picker.colors
Adjust(st, st.rows[colourRow], 1)
check(st.color == 1, "colour wraps from last to first")
Adjust(st, st.rows[colourRow], -1)
check(st.color == #picker.colors, "and back from first to last")

for i, row in ipairs(st.rows) do if row.adjust == "thickness" then thickRow = i end end
st.thickness = 40
Adjust(st, st.rows[thickRow], 1)
check(HR_THICKNESS_CHOICES[st.thickness] == 0.1, "thickness wraps from 4.0 to 0.1")
Adjust(st, st.rows[thickRow], -1)
check(HR_THICKNESS_CHOICES[st.thickness] == 4, "and back from 0.1 to 4.0")
check(NormalizeHex("F56C27") == "#F56C27", "a bare hex gains its hash")
check(NormalizeHex("#FFF") == nil and NormalizeHex("pink") == nil, "junk is rejected")

profiles = { { dir = "/p1/", name = "x", ini = { gotempo = { Thickness = 1.4, Color = "#F56C27" } } } }
PROFILEMAN.GetProfileDir = function(_, _) return "/p1/" end
local style = ProfileStyle(1)
check(style.thickness == 1.5 * 1.4, "Thickness multiplies the configured width")
check(style.scale == 1.4, "the rounded multiplier is kept for the picker")
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
