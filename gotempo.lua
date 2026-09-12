-- Heart rate display for Simply Love
--
-- Reads BPM values from Modules/hr.txt (and hr-p2.txt with two players joined)
-- and draws them onto ScreenGameplay.
--
-- It also writes the other direction.  players.txt, beside those files, tells
-- gotempo who is playing and which strap each of them says is theirs, read from
-- their own game profile.  That is what lets a regular at a cabinet use their
-- own belt without anyone walking round to the PC to pick it from a menu.
--
-- File format, one line:   "<bpm> <YYYYMMDD> <secondsSinceLocalMidnight>"
--                    e.g.  "154 20260904 52327"
--
-- The first number is the heart rate; leading zeroes and a trailing newline are
-- both fine, and two-digit values are zero-padded for display.  The date and
-- time fields are optional, and are how we tell a live sensor from one that was
-- never connected this session: once they fall further than STALE_AFTER_SECONDS
-- behind our own clock the whole panel hides itself.  Omit them and the
-- staleness check is skipped entirely.
--
-- A date and a time of day rather than a Unix epoch because this engine does not
-- expose the Lua `os` library -- there is no os.time/os.date to convert one --
-- but it does expose Year()/MonthOfYear()/DayOfMonth()/Hour()/Minute()/Second(),
-- so both sides can agree on a wall-clock reading for free.  Both sides must
-- therefore use local time.
--
-- Two layouts, because the free space on this screen is not the same in each:
--
-- One player joined: the panel sits in the ScreenGameplay header -- the 80px
-- black bar across the top, drawn by Shared/Header.lua.  Its middle is taken by
-- the song meter and that player's score sits just inside it, which leaves the
-- far corner opposite free in every layout: centred or not, and whatever
-- DataVisualizations is set to.
--
-- Two players joined: both header corners are taken, so the panels move to the
-- bottom centre, either side of the game-mode text.  That strip is the one part
-- of a two-player screen that keeps its shape whatever modifiers are on -- the
-- playfields and their surrounding readouts all move, and a player with hidden
-- targets frees space that a player without the modifier still uses.  It is
-- measured as a fraction of the screen rather than in pixels, since the two
-- halves of a cabinet pair need not run the same resolution.

-------------------------------------------
-------( Configuration Parameters )--------
-------------------------------------------

-- P1 reads hr.txt, P2 reads hr-p2.txt, always, including a player alone on the
-- P2 side.  gotempo puts the strap on the side that is actually joined, which it
-- learns from players.txt below, so the file a panel reads is always the file
-- its own side is written to.
-- Everything this module owns lives in one folder beside it.  The .lua itself
-- cannot: the loader lists Modules/ without recursing and keeps only *.lua, so a
-- nested module is never loaded (verified, not assumed).  Its files can, which
-- at least keeps them from being loose among every other module's.
local GOTEMPO_DIR = THEME:GetCurrentThemeDirectory() .. "Modules/gotempo/"

local HR_FILES = {
	GOTEMPO_DIR .. "hr.txt",
	GOTEMPO_DIR .. "hr-p2.txt",
}
local POLL_SECONDS = 1

-- Published beside hr.txt for gotempo to read, once a second:
--
--	20260908 52327
--	p1 24:AC:AC:18:41:CC
--	p2 -
--
-- A line means that side is joined, "-" means joined having named no strap, and
-- no line means nobody is there.  gotempo needs all three: "nobody is on P2" and
-- "someone is on P2 who configured nothing" want opposite behaviour, the first
-- leaving that slot idle and the second putting the configured strap on it.
--
-- The stamp is this module's own clock, in the same format hr.txt carries the
-- other way.  It is what releases the straps when the game exits or crashes:
-- there is no goodbye to send, so a stamp that stops advancing is the signal.
local PLAYERS_FILE = GOTEMPO_DIR .. "players.txt"

-- The strap list the picker reads, published by gotempo when asked and blanked
-- again about a minute later.  The module has no Bluetooth -- that is the whole
-- point of the split -- so asking is the only way to find out what is in range.
-- The request travels as a "scan <token>" line in players.txt above, inheriting
-- that file's stamp rather than needing a channel of its own; gotempo serves a
-- token it has not served before, so the line can sit there for as long as the
-- picker is open, and a retry is simply a new token.
local DEVICES_FILE = GOTEMPO_DIR .. "devices.txt"
local DEVICES_MAX_AGE = 90		-- seconds; older than this is not an answer
local SCAN_WAIT = 20			-- seconds before giving up on gotempo

-- The sort menu row, as {toptext, bottomtext}.  The bottom line is the larger of
-- the two, so the name goes there and the description sits above it.
--
-- Neither needs a Languages entry: the wheel item falls back to the literal
-- string when the theme has no lookup for it.  The bottom text must not start
-- with "Category", which the theme strips as a submenu prefix -- and it is also
-- the key the theme dispatches on, so it is what custom_functions is keyed by.
local SORTMENU_TOP = "HR Strap Config"
local SORTMENU_BOTTOM = "gotempo"

-- The heart-rate line drawn over the density graph on the evaluation screen.
--
-- Samples are collected once a second during gameplay, against the song's own
-- clock rather than a tick count, so the line shares an x-axis with the density
-- graph underneath it without any correction.  They live in memory only: the
-- module chunk is loaded once for the program's life, so a table here survives
-- gameplay to evaluation, and nothing needs to reach the disk.
--
-- A vertex per second draws a line that shakes with ordinary sensor noise. The
-- samples are bucketed into a fixed number of evenly spaced points instead, so a
-- ninety-second song and a ten-minute one get the same treatment, and then run
-- through a short moving average so what is left reads as effort rather than
-- jitter.  Raise HR_GRAPH_POINTS for detail, HR_GRAPH_SMOOTH for calm.
-- The line scales to the readings rather than to a fixed range, so a song spent
-- between 102 and 108 shows its shape instead of a flat streak.  That trades
-- away comparability between songs: every graph fills the box, and the only
-- thing saying whether it was a warmup or a wall is the labels.  They are not
-- decoration here.
local HR_GRAPH = true
local HR_GRAPH_POINTS = 64
local HR_GRAPH_SMOOTH = 1		-- moving-average window, in points; 1 disables
local HR_GRAPH_PAD = 0.1		-- headroom above the peak and below the trough
local HR_GRAPH_THICKNESS = 1.5		-- half-width of the drawn ribbon, across the line
local HR_GRAPH_COLOR = { 1, 0.31, 0.64, 1 }	-- pink, distinct from the lifebar and the scatter dots

-- The min, max and mean readings, written up the right-hand edge at the height
-- each one sits at.  The mean is dropped when it would collide with one of the
-- other two, since those define the scale and it does not.
-- Up the left edge, where the song's lead-in leaves the density graph empty.
local HR_LABEL_ZOOM = 0.13
local HR_LABEL_INSET = 1		-- from the left edge of the box
local HR_LABEL_PAD = 2			-- around the text, inside its backing
local HR_LABEL_COLOR = { 1, 0.31, 0.64, 1 }
local HR_LABEL_BG = { 0, 0, 0, 0.65 }	-- the density bars run underneath

-- The mean also gets a rule across the whole box, faint enough to read as a
-- reference rather than as another series.
local HR_MEAN_LINE = { 1, 0.31, 0.64, 0.5 }
local HR_MEAN_LINE_H = 0.7

-- A gap in the readings is drawn as a gap.  Two separate things can stop them:
-- the strap coming off skin, and the connection dropping.  Neither is announced,
-- but gotempo rewrites hr.txt on every reading with a fresh timestamp -- the
-- timestamp is the payload, not the bpm -- so a stamp that stops advancing means
-- nothing arrived.
--
-- Both clocks tick once a second and neither is synchronised to the other, so
-- seeing the same stamp twice happens while perfectly healthy.  Three in a row
-- does not.
local HR_STALE_POLLS = 3
local HR_GRAPH_GAP = 3			-- seconds of silence that break the line

-- The line is drawn over the density graph, so it can sit on top of the timing
-- dots a player wants to read.  This folds it away at the evaluation screen and
-- brings it back, per side, for as long as the game is running.  Deliberately
-- not MenuUp: on a pad that is part of the theme's favourite-song code, and the
-- line would flicker while somebody entered it.
local HR_GRAPH_TOGGLE = "MenuDown"

-- What the in-game picker's appearance rows offer.  Presets rather than free
-- entry: there is no keyboard at a cabinet, and a palette is quicker than
-- stepping a hex value one digit at a time.  The first colour is the default.
local HR_COLOR_CHOICES = {
	"#FF4FA3", "#F56C27", "#FFC24B", "#13BE74",
	"#4DB8FF", "#B07CFF", "#FF5555", "#FFFFFF",
}
local HR_THICKNESS_CHOICES = { 0.6, 0.8, 1.0, 1.2, 1.4, 1.7, 2.0, 2.5 }

-- A heart in the corner of every other screen, so the wait for a strap to
-- connect is visible somewhere other than the tray.  Lit and beating when that
-- side's reading is arriving, dim when not: connecting can take a good few
-- seconds and a strap that is asleep or off skin never connects at all, which
-- is otherwise indistinguishable from the module being broken.
--
-- One per side, P1 bottom left and P2 bottom right, so two straps can be told
-- apart at a glance.  P1's is always up; P2's would be permanent clutter on a
-- one-strap setup, so it appears only once that side has joined or has a
-- reading of its own.
local STATUS_HEART = true
local STATUS_HEART_SIZE = 14
local STATUS_HEART_MARGIN = 8		-- from the screen corner
local STATUS_HEART_LIVE = { 1, 0.18, 0.31, 1 }
local STATUS_HEART_DEAD = { 1, 1, 1, 0.18 }
local STATUS_HEART_SCREENS = {
	"ScreenTitleMenu", "ScreenSelectProfile", "ScreenSelectPlayMode",
	"ScreenSelectStyle", "ScreenSelectMusic", "ScreenPlayerOptions",
}

-- Simply Love's evaluation layout, which a module has to recompute because it
-- draws in ScreenSystemLayer and cannot reach that screen's actors.  From
-- BGAnimations/ScreenEvaluation common/PerPlayer/Lower/{default,Graphs}.lua.
-- If the graph drifts off its box after a theme update, these are why.
local EVAL_PANE_W = 300
local EVAL_PANE_GAP = 10
local EVAL_ONE_PLAYER_NUDGE = 0.2541
local EVAL_GRAPH_Y = 124		-- below _screen.cy

-- Where a player names their strap, in their own profile, following the
-- convention ArrowCloud and GrooveStats already use:
--
--	[gotempo]
--	Device=24:AC:AC:18:41:CC
local PROFILE_INI = "gotempo.ini"
local PROFILE_SECTION = "gotempo"
local PROFILE_KEY = "Device"

-- Optional appearance keys in the same section, so a player can make their own
-- line legible against whatever they play on.  Both fall back to the values
-- above when missing, empty or malformed:
--
--	Color=#FF4FA3		the line, its labels and the mean rule
--	Thickness=1.4		multiplies HR_GRAPH_THICKNESS, at every slope
local PROFILE_KEY_COLOR = "Color"
local PROFILE_KEY_THICKNESS = "Thickness"
local HR_THICKNESS_MAX = 4		-- a typo should not fill the box

-- Paint the panel background a bright colour and keep it visible even with no
-- reading, so you can see exactly what space it occupies while positioning it.
-- Turn this off once you are happy with the geometry.
local DEBUG_BG = false
local DEBUG_BG_COLORS = {
	color("#ff00ffcc"),	-- P1: magenta
	color("#00ffffcc"),	-- P2: cyan
}

-- The header is 80px tall, so a 50px panel at y=15 sits centred in it.
local PANEL_Y = 15
local PANEL_HEIGHT = 50
local PANEL_WIDTH = 170
local PANEL_MARGIN = 10		-- gap between the panel and the screen edge
local PADDING = 5

-- Two-player placement, as fractions of the screen width measured out from the
-- centre.  DUAL_INSET clears the game-mode text in the middle; DUAL_OUTSET is
-- how far out each panel reaches.  The difference between them is the panel
-- width, so widening one without the other changes the size, not just the gap.
--
-- Note the units: this theme designs against a 480-tall screen with the width
-- following the aspect ratio (_fallback/metrics.ini, ScreenWidth=1), so 16:9 is
-- about 854x480 and everything here is in that space, not display pixels.  A
-- fraction of 0.12 is therefore ~103 of those units, against the 170 the
-- single-player header panel gets.
--
-- DUAL_INSET is the real setting.  DUAL_OUTSET is only a fallback: the outer
-- edge is normally computed from where the playfield beside the panel actually
-- starts, via the theme's own GetNotefieldX/GetNotefieldWidth.  Those account
-- for the game, the style, and NoteFieldOffsetX, which is a *per-player*
-- modifier -- so the two fields are not necessarily the same distance from the
-- centre and a symmetric hardcoded number would put one panel over the notes.
--
-- The space this leaves is genuinely tight.  At 16:9 with dance/versus, each
-- field's inner edge is 85 units from the centre and the game-mode text needs
-- ~36, so a panel gets about 45 units against the 170 the header panel enjoys.
local DUAL_INSET = 0.042
local DUAL_OUTSET = 0.10

-- Clearance between a panel and the playfield beside it.
local DUAL_FIELD_GAP = 4

-- Floor on the panel width.  Only reached by a style whose fields are wide
-- enough to leave no room, where a slightly overlapping readout still beats one
-- that silently is not there.
local DUAL_MIN_WIDTH = 40

-- The two-player panel stacks the heart above the digits instead of setting them
-- side by side, which is what makes the digits legible in so narrow a slot:
-- sharing a row with the icon caps them near zoom 0.15, a row of their own
-- reaches ~0.29.  Both rows are centred on the panel, so the two panels are
-- symmetric without either needing to be mirrored.
--
-- The stack is laid out upward from DUAL_DIGIT_BOTTOM rather than centred in the
-- panel: the digits sit beside the game-mode text and want to agree with its
-- line, so they get the fixed position and the heart grows away from them.
-- Raise DUAL_DIGIT_BOTTOM to move the digits up, lower it to move them down.
-- Because the panel is anchored to the screen bottom, the digits land at
-- (screen height - DUAL_MARGIN_BOTTOM - DUAL_DIGIT_BOTTOM) whatever DUAL_HEIGHT
-- is: height only decides how much room the heart has above them.
local DUAL_PADDING = 2		-- inset inside the panel; smaller than PADDING, the slot is tight
local DUAL_TEXT_SCALE = 1	-- fraction of "three digits fill the panel width"
local DUAL_ICON_SCALE = 2.4	-- heart height relative to the digits' cap height
local DUAL_STACK_GAP = 9.5	-- gap between the heart and the digits
local DUAL_DIGITS = 3		-- the readout is three digits wide
local DUAL_DIGIT_BOTTOM = 23	-- panel bottom to the digits' centre line

-- Panels are anchored to the bottom edge rather than centred in the space below
-- the score list, because that list grows downward as entries are added and
-- would otherwise crowd them.  The height is what the stack needs -- the digits'
-- line plus the heart above it -- not a box drawn around free space, so raising
-- DUAL_ICON_SCALE means raising this too or the heart clips out of the top.
local DUAL_HEIGHT = 64
local DUAL_MARGIN_BOTTOM = 6

-- Which corner the single-player panel sits in.  "auto" picks the one opposite
-- that player's score display, which is the free one: P1's score sits left of
-- centre, P2's right of it.  Force it with "left" or "right" if something in
-- your setup claims that corner -- the NPSGraphAtTop modifier is the one that
-- does, since it pushes the BPM readout out of the centre and into exactly this
-- space.  Ignored with two players joined.
local CORNER_SIDE = "auto"

-- Metrics of Wendy/_wendy monospace numbers at zoom 1, from its .ini.
local DIGIT_WIDTH = 48		-- DefaultWidth
local FONT_TOP = 18		-- Top
local FONT_BASELINE = 50	-- Baseline
local SLOTS = 4			-- icon + three digits

local CAP_HEIGHT = FONT_BASELINE - FONT_TOP

-- valign(0.5) does not put this font's glyph ink where you'd expect: it lands
-- some way below the actor's own y, times zoom.  Shift the DIGITS up to cancel
-- it.  Tuned by eye rather than derived.  Bigger moves the digits up; one unit
-- is about 0.7px on screen.
local INK_OFFSET = 22

-- Moves the ICON only, in panel pixels.  Negative is up.
local ICON_Y_NUDGE = -5

-- TEXT_SCALE is a fraction of "icon plus three digits fills the panel width".
-- 1 fills it edge to edge; smaller is flush against the left edge.
local TEXT_SCALE = 0.84
local ICON_SCALE = 1.6		-- icon height relative to the digits' cap height
local ICON_GAP = 6		-- gap between icon and digits

-- Resolved relative to this module's own directory, not the theme root, so the
-- subfolder is part of the path.
local ICON_TEXTURE = "gotempo/heart (mipmaps).png"

-- The monospace number font only contains "1234567890.:/ ", so the no-data
-- placeholder can only use those characters.
local STALE_TEXT = "..."
local STALE_ALPHA = 0.35	-- icon dim when there is no reading

local PULSE = true		-- beat the icon at the current heart rate
local PULSE_MAGNITUDE = 1.15

-- Transparent by default: the header is already a dark bar, and so is the centre
-- column the two-player panels sit against, so a second black quad on top of
-- either shows up as a visibly darker rectangle.  Give this an alpha if you move
-- a panel somewhere with no backdrop of its own.
local BG_COLOR = color("#00000000")
local TEXT_COLOR = color("#ffffff")
local STALE_COLOR = color("#555555")

-- MIN_BPM is load-bearing beyond sanity checking: it is what guarantees bpm > 0
-- before effectperiod(60/bpm) further down, and 60/0 is inf in Lua 5.1.  Do not
-- remove the range check without putting a zero guard on the pulse first.
--
-- MAX_BPM is the 3-digit display slot, not a claim about physiology: 999 is the
-- largest value string.format("%03d", n) renders in three characters.
local MIN_BPM = 20
local MAX_BPM = 999

-- Hide the panel once the reading's timestamp is this far behind our clock.  The
-- point of this is the "no heart rate device at all this session" case, not
-- catching brief sensor dropouts -- a mildly old number on screen is harmless --
-- so it is set generously.  Keep it well above 1s: Second() has 1s resolution.
local STALE_AFTER_SECONDS = 60

-- false keeps the old behaviour instead: panel stays put, digits go to "..." and
-- the heart dims, rather than disappearing.
local HIDE_WHEN_STALE = true

-------------------------------------------
----( End of configuration parameters )----
-------------------------------------------

-- Per-panel state, indexed 1/2 for P1/P2.  A table rather than a set of
-- file-scope values because both panels live in one module: a single `bpm` would
-- have the two of them overwrite each other every poll.
local state = {
	{ bpm=nil, pulseBpm=nil, geo=nil, file=HR_FILES[1], samples={}, stamp=nil, repeats=0 },
	{ bpm=nil, pulseBpm=nil, geo=nil, file=HR_FILES[2], samples={}, stamp=nil, repeats=0 },
}


local function secondsOfDay()
	return Hour()*3600 + Minute()*60 + Second()
end


-- YYYYMMDD as an integer.  MonthOfYear() is 0-based, hence the +1.
local function todayStamp()
	return Year()*10000 + (MonthOfYear()+1)*100 + DayOfMonth()
end


local function ReadHeartRate(path)
	local file = RageFileUtil.CreateRageFile()
	local text = nil

	if file:Open(path, 1) then
		text = file:Read()
		file:Close()
	end
	file:destroy()

	if text == nil then return nil end

	local digits = text:match("%d+")
	if digits == nil then return nil end

	local value = tonumber(digits)
	if value == nil or value < MIN_BPM or value > MAX_BPM then return nil end

	-- Optional trailing fields: the writer's local date and time of day.  The date
	-- is what makes "no device this session" actually work -- a time of day alone
	-- cannot tell yesterday's leftover file from a live reading taken at the same
	-- hour today, so a file left behind by an earlier session would look fresh.
	-- Absent fields mean the check is skipped entirely.
	local stampDate, stampSecs = text:match("%d+%D+(%d+)%D+(%d+)")
	local stamp = stampDate and stampSecs and (stampDate .. ":" .. stampSecs) or nil
	if stampDate and stampSecs then
		if tonumber(stampDate) ~= todayStamp() then return nil end

		-- Same calendar day, so this can only go negative on clock skew; treat a
		-- timestamp from the near future as fresh rather than ancient.  Midnight
		-- rollover needs no special case: the date stops matching for the one poll
		-- it takes the writer to catch up.
		local age = secondsOfDay() - tonumber(stampSecs)
		if age < 0 then age = 0 end
		if age > STALE_AFTER_SECONDS then return nil end
	end

	return value, stamp
end


-- How far from the centre this player's playfield begins, in screen units.
-- Returns nil when the theme cannot say (no style yet, or a game whose width it
-- does not have a figure for), leaving the caller to fall back to DUAL_OUTSET.
local function FieldEdgeFromCentre(pn)
	if GetNotefieldX == nil or GetNotefieldWidth == nil then return nil end

	local x = GetNotefieldX((pn == 1) and PLAYER_1 or PLAYER_2)
	local w = GetNotefieldWidth()
	if not x or not w then return nil end

	return math.abs(x - _screen.cx) - w/2
end


local PROFILE_SLOTS = { "ProfileSlot_Player1", "ProfileSlot_Player2" }
local SIDES = { "PlayerNumber_P1", "PlayerNumber_P2" }


-- The strap this side's player named in their profile, or nil.  Empty when no
-- explicit profile is loaded, which is the usual case for a casual player: they
-- simply get whatever the machine is set to.
local function ProfileDevice(pn)
	if PROFILEMAN == nil or IniFile == nil then return nil end

	local dir = PROFILEMAN:GetProfileDir(PROFILE_SLOTS[pn])
	if not dir or #dir == 0 then return nil end

	local contents = IniFile.ReadFile(dir .. PROFILE_INI)
	if not contents or not contents[PROFILE_SECTION] then return nil end

	local mac = contents[PROFILE_SECTION][PROFILE_KEY]
	if type(mac) ~= "string" or #mac == 0 then return nil end
	return mac
end


-- A profile's colour, as hex, validated before color() sees it: a typo in a
-- file gotempo never writes should fall back, not take the graph down.
local function NormalizeHex(text)
	if type(text) ~= "string" then return nil end
	local hex = text:match("^%s*#?(%x+)%s*$")
	if hex == nil or (#hex ~= 6 and #hex ~= 8) then return nil end
	return "#" .. hex
end


local function ParseColor(text)
	local hex = NormalizeHex(text)
	if hex == nil then return nil end
	return color(hex)
end


-- A profile's line thickness, as a multiplier. Zero or negative would erase the
-- line, which the toggle already does better.
local function ParseThickness(text)
	local n = tonumber(text)
	if n == nil or n <= 0 or n > HR_THICKNESS_MAX then return nil end
	return n
end


-- Appearance settings for one side, read fresh every time.
--
-- Not cached.  It was, keyed on the profile directory, which looked safe until
-- the in-game picker started writing that file: the directory does not change
-- when its contents do, so a saved thickness or colour was ignored for the rest
-- of the session and both sides drew at the default.  There are only two callers
-- -- the evaluation graph, once per side per screen, and the picker when it
-- opens -- so nothing here is hot enough to be worth a cache that can go stale.
-- ProfileDevice is the one that runs every second, and it is separate.
local function ProfileStyle(pn)
	local style = { color = HR_GRAPH_COLOR, thickness = HR_GRAPH_THICKNESS }
	if PROFILEMAN == nil or IniFile == nil then return style end

	local dir = PROFILEMAN:GetProfileDir(PROFILE_SLOTS[pn])
	if dir == nil or #dir == 0 then return style end

	local contents = IniFile.ReadFile(dir .. PROFILE_INI)
	local section = contents and contents[PROFILE_SECTION]
	if section ~= nil then
		-- colorHex is kept alongside the parsed colour so the picker can show
		-- which preset this profile is on without re-reading the file.
		local hex = NormalizeHex(section[PROFILE_KEY_COLOR])
		if hex ~= nil then style.color, style.colorHex = color(hex), hex end
		local scale = ParseThickness(section[PROFILE_KEY_THICKNESS])
		if scale ~= nil then style.thickness = HR_GRAPH_THICKNESS * scale end
	end
	return style
end


-- ── the strap picker ────────────────────────────────────────────────────────
--
-- Finding your own strap's MAC otherwise means a terminal and `--list-devices`,
-- which at a cabinet means nobody ever names one and the profile feature goes
-- unused.  This puts it in the game: open the sort menu, pick your strap off a
-- list, and it is written into your own profile.

-- ReadDevices returns gotempo's answer as {mac=, name=}, newest first by MAC
-- order, or nil when there is no usable answer yet.  Empty is not nil: gotempo
-- blanks the file about a minute after publishing, and an empty file means "the
-- list has expired", not "still waiting".
local function ReadDevices()
	local file = RageFileUtil.CreateRageFile()
	local text = nil
	if file:Open(DEVICES_FILE, 1) then
		text = file:Read()
		file:Close()
	end
	file:destroy()

	if text == nil or text == "" then return nil end

	local lines = {}
	for line in text:gmatch("[^\r\n]+") do lines[#lines+1] = line end
	if #lines == 0 then return nil end

	-- Same stamp the other two files carry, and rejected the same way: nothing
	-- in this channel can send a goodbye, so an answer that stopped being
	-- rewritten has to age out rather than be withdrawn.
	local date, secs = lines[1]:match("^(%d+)%s+(%d+)$")
	if date == nil then return nil end
	if tonumber(date) ~= todayStamp() then return nil end
	local age = secondsOfDay() - tonumber(secs)
	if age < 0 then age = 0 end
	if age > DEVICES_MAX_AGE then return nil end

	local out = {}
	for i = 2, #lines do
		local mac, name = lines[i]:match("^(%S+)%s*(.*)$")
		if mac ~= nil then
			out[#out+1] = { mac = mac, name = (name ~= "" and name or mac) }
		end
	end
	return out
end


-- Every local profile that names a strap, as MAC -> { display names }.
--
-- This is what makes the list usable where it matters.  A venue with three cabs
-- in one room has six people playing and more standing about, so a scan can turn
-- up a dozen straps; without owner names they are an undifferentiated column of
-- hex and nobody can tell which are free.
--
-- Enumeration follows the theme's own, in
-- BGAnimations/ScreenSelectProfile underlay/PlayerProfileData.lua.
local function StrapOwners()
	local owners = {}
	if PROFILEMAN == nil or IniFile == nil then return owners end

	for i = 1, PROFILEMAN:GetNumLocalProfiles() do
		-- Both index calls are 0-based.
		local profile = PROFILEMAN:GetLocalProfileFromIndex(i - 1)
		local id = PROFILEMAN:GetLocalProfileIDFromIndex(i - 1)
		local dir = id and PROFILEMAN:LocalProfileIDToDir(id)

		if profile ~= nil and dir ~= nil and #dir > 0 then
			local contents = IniFile.ReadFile(dir .. PROFILE_INI)
			local section = contents and contents[PROFILE_SECTION]
			local mac = section and section[PROFILE_KEY]
			if type(mac) == "string" and #mac > 0 then
				local key = mac:upper()
				owners[key] = owners[key] or {}
				table.insert(owners[key], profile:GetDisplayName())
			end
		end
	end
	return owners
end


-- The list as one side sees it: the strap that side already holds, then ones
-- nobody claims, then a divider and the rest.  Position alone answers "which of
-- these is free", so nothing has to be read to find one.  Claimed straps stay
-- listed and stay pickable, because sharing a strap is a legitimate thing to do.
--
-- mine is that side's own strap, and it is first rather than filed under "in use
-- by others", which is what it would otherwise be: the profile claiming it is
-- theirs.
local function PickerRows(devices, owners, mine)
	local own, free, used = {}, {}, {}
	for _, d in ipairs(devices) do
		local who = owners[d.mac:upper()]
		local row = { mac = d.mac, name = d.name, owners = who }

		if mine ~= nil and d.mac:upper() == mine:upper() then
			row.yours, row.owners = true, nil
			own[#own+1] = row
		else
			table.insert(who and used or free, row)
		end
	end

	local byName = function(a, b) return a.name:lower() < b.name:lower() end
	table.sort(free, byName)
	table.sort(used, byName)

	local rows = own
	for _, row in ipairs(free) do rows[#rows+1] = row end
	if #used > 0 then
		if #rows > 0 then rows[#rows+1] = { divider = true } end
		for _, row in ipairs(used) do rows[#rows+1] = row end
	end
	return rows
end


-- Commits one side's choices to that player's own profile.  Everything outside
-- this module's section is left alone, and a nil device removes the key rather
-- than writing an empty one.
--
-- st carries indices into the choice tables rather than values, because that is
-- what the adjuster rows step through.
local function WriteProfileSettings(pn, st)
	if PROFILEMAN == nil or IniFile == nil then return false end
	local dir = PROFILEMAN:GetProfileDir(PROFILE_SLOTS[pn])
	if dir == nil or #dir == 0 then return false end

	local path = dir .. PROFILE_INI
	local contents = IniFile.ReadFile(path) or {}
	local section = contents[PROFILE_SECTION] or {}
	contents[PROFILE_SECTION] = section

	section[PROFILE_KEY] = st.device
	section[PROFILE_KEY_COLOR] = HR_COLOR_CHOICES[st.color]
	section[PROFILE_KEY_THICKNESS] = HR_THICKNESS_CHOICES[st.thickness]

	IniFile.WriteFile(path, contents)
	return true
end


-- Whether each side's line is drawn, toggled with HR_GRAPH_TOGGLE.  Module-level
-- so the choice survives the next song rather than having to be made again on
-- every evaluation screen.
local graphShown = { true, true }


-- Publishes who is playing.  Called on every tick rather than on screen entry:
-- the stamp is the payload, so a file that stops being rewritten is how gotempo
-- learns the game is gone.  Sides are reported even when they name no strap.
-- Non-nil while the picker wants a device list.  Carried in players.txt on the
-- next tick, and kept there until the picker closes: gotempo ignores a token it
-- has already served, so repeating it costs nothing.
local scanToken = nil

local function RequestScan()
	scanToken = secondsOfDay()
	return scanToken
end

local function CancelScan() scanToken = nil end


local function WritePlayers()
	local lines = { string.format("%04d%02d%02d %d",
		Year(), MonthOfYear() + 1, DayOfMonth(), secondsOfDay()) }

	for pn = 1, 2 do
		if GAMESTATE:IsSideJoined(SIDES[pn]) then
			lines[#lines+1] = string.format("p%d %s", pn, ProfileDevice(pn) or "-")
		end
	end
	if scanToken ~= nil then
		lines[#lines+1] = string.format("scan %d", scanToken)
	end

	local file = RageFileUtil.CreateRageFile()
	if file:Open(PLAYERS_FILE, 2) then
		file:Write(table.concat(lines, "\n") .. "\n")
		file:Close()
	end
	file:destroy()
end


-- Returns {x, y, w, h} for a player's panel, or nil when they have none this
-- round: either that side is not joined, or (one player, CORNER_SIDE forced)
-- there is no corner for them.
local function PanelGeometry(pn)
	local joined = {
		GAMESTATE:IsSideJoined("PlayerNumber_P1"),
		GAMESTATE:IsSideJoined("PlayerNumber_P2"),
	}
	if not joined[pn] then return nil end

	-- Two players: flank the game-mode text along the bottom edge, each panel on
	-- its own player's side of centre.
	if joined[1] and joined[2] then
		local inset = DUAL_INSET * _screen.w

		-- Reach out to the playfield beside us, or to the fallback fraction when
		-- the theme cannot tell us where that is.
		local edge = FieldEdgeFromCentre(pn)
		local outset = edge and (edge - DUAL_FIELD_GAP) or (DUAL_OUTSET * _screen.w)
		if outset - inset < DUAL_MIN_WIDTH then
			outset = inset + DUAL_MIN_WIDTH
		end

		return {
			x = (pn == 1) and (_screen.cx - outset) or (_screen.cx + inset),
			y = _screen.h - DUAL_HEIGHT - DUAL_MARGIN_BOTTOM,
			w = outset - inset,
			h = DUAL_HEIGHT,
			stacked = true,
		}
	end

	-- One player: the header corner opposite their score.
	local side = CORNER_SIDE
	if side == "auto" then side = joined[1] and "right" or "left" end

	local x = PANEL_MARGIN
	if side == "right" then x = _screen.w - PANEL_WIDTH - PANEL_MARGIN end

	return { x = x, y = PANEL_Y, w = PANEL_WIDTH, h = PANEL_HEIGHT, stacked = false }
end


-- Everything the children need to lay themselves out, derived from the panel
-- size so the readout scales with it rather than being hardcoded.  The
-- two-player panels are narrower than the header one, so this has to follow
-- whatever size it is handed.
local function ContentGeometry(w, h, stacked)
	-- Stacked: digits on their own row above a centred heart.  The digits get the
	-- panel's whole width rather than sharing it with the icon, which is the
	-- whole point -- side by side in the two-player slot they cap out around zoom
	-- 0.15, on their own row they reach about twice that.  Both rows are centred,
	-- so the two panels are symmetric without either being mirrored.
	if stacked then
		local digitZoom = ((w - DUAL_PADDING*2) / (DUAL_DIGITS * DIGIT_WIDTH)) * DUAL_TEXT_SCALE
		local capHeight = CAP_HEIGHT * digitZoom
		local iconSize = capHeight * DUAL_ICON_SCALE

		-- Built upward from the digits' line, not centred as a block: the digits
		-- have to agree with the game-mode text beside them, so resizing the
		-- heart must move the heart rather than shifting them off that line.
		local digitCentre = h - DUAL_DIGIT_BOTTOM

		return {
			width=w,
			height=h,
			digitZoom=digitZoom,
			digitAlign=0.5,
			digitX=w/2,			-- both rows centred, so the heart sits over the digits
			digitY=digitCentre - INK_OFFSET*digitZoom,
			iconSize=iconSize,
			iconX=w/2,			-- centred, so it can pulse in place
			iconY=digitCentre - capHeight/2 - DUAL_STACK_GAP - iconSize/2,
		}
	end

	-- Side by side: heart then digits, filling the width in one row.
	local slot = (w - PADDING*2) / SLOTS
	local digitZoom = (slot / DIGIT_WIDTH) * TEXT_SCALE
	local iconSize = CAP_HEIGHT * digitZoom * ICON_SCALE

	return {
		width=w,
		height=h,
		digitZoom=digitZoom,
		digitAlign=0,
		digitX=PADDING + iconSize + ICON_GAP,
		digitY=h/2 - INK_OFFSET*digitZoom,
		iconSize=iconSize,
		iconX=PADDING + iconSize/2,	-- centred, so it can pulse in place
		iconY=h/2 + ICON_Y_NUDGE,
	}
end


-- One player's panel.  pn is 1 or 2 and is captured by every command below, so
-- each panel touches only its own slot of `state`.
local function Panel(pn)
	return Def.ActorFrame{
		SetupCommand=function(self)
			local g = PanelGeometry(pn)
			state[pn].geo = g
			state[pn].bpm = nil
			state[pn].pulseBpm = nil
			state[pn].samples = {}	-- one song's worth; the graph reads it on evaluation
			state[pn].stamp, state[pn].repeats = nil, 0

			-- Stay hidden until the first Tick has actually read the file, so
			-- entering gameplay never flashes a frame of placeholder text.
			self:visible(false)
			if g == nil then return end

			self:xy(g.x, g.y)
			self:playcommand("SetGeometry", ContentGeometry(g.w, g.h, g.stacked))
		end,

		RefreshCommand=function(self)
			local s = state[pn]
			-- Re-evaluated every poll, not just on screen entry: the sensor can
			-- drop out mid-song and should bring the panel back on its own when it
			-- returns.  DEBUG_BG pins it visible so the space it occupies can be
			-- seen without a strap connected.
			self:visible(s.geo ~= nil and (DEBUG_BG or s.bpm ~= nil or not HIDE_WHEN_STALE))
		end,

		Def.Quad{
			InitCommand=function(self)
				self:halign(0):valign(0)
				self:diffuse(DEBUG_BG and DEBUG_BG_COLORS[pn] or BG_COLOR)
			end,
			SetGeometryCommand=function(self, params)
				self:zoomto(params.width, params.height)
			end,
		},

		-- The icon lives inside its own frame so the pulse effect scales the frame
		-- (base zoom 1) rather than fighting with the sprite's own sizing zoom.
		Def.ActorFrame{
			SetGeometryCommand=function(self, params)
				self:xy(params.iconX, params.iconY)
				self:GetChild("Icon"):playcommand("SizeIcon", params)
			end,

			RefreshCommand=function(self)
				local s = state[pn]
				if s.bpm == nil then
					self:stopeffect()
					s.pulseBpm = nil
				elseif PULSE and s.bpm ~= s.pulseBpm then
					self:pulse():effectmagnitude(1, PULSE_MAGNITUDE, 0):effectperiod(60/s.bpm)
					s.pulseBpm = s.bpm
				end
			end,

			Def.Sprite{
				Name="Icon",
				Texture=ICON_TEXTURE,
				SizeIconCommand=function(self, params)
					self:zoomto(params.iconSize, params.iconSize)
				end,
				RefreshCommand=function(self)
					self:diffusealpha(state[pn].bpm and 1 or STALE_ALPHA)
				end,
			},
		},

		LoadFont("Wendy/_wendy monospace numbers")..{
			Text=STALE_TEXT,
			InitCommand=function(self)
				self:valign(0.5)
			end,
			SetGeometryCommand=function(self, params)
				-- halign belongs here rather than in InitCommand: stacked digits
				-- are centred, side-by-side ones are anchored left.
				self:halign(params.digitAlign)
				self:zoom(params.digitZoom)
				self:xy(params.digitX, params.digitY)
			end,
			RefreshCommand=function(self)
				local bpm = state[pn].bpm
				if bpm then
					self:settext(string.format("%03d", bpm)):diffuse(TEXT_COLOR)
				else
					self:settext(STALE_TEXT):diffuse(STALE_COLOR)
				end
			end,
		},
	}
end


-- Where ScreenEvaluation draws this player's graph box, in screen units.
-- Recomputed from the theme's own layout: see the EVAL_ constants above.
local function EvalGraphBox(pn)
	local players = #GAMESTATE:GetHumanPlayers()
	local w = THEME:GetMetric("GraphDisplay", "BodyWidth")
	local h = THEME:GetMetric("GraphDisplay", "BodyHeight")

	-- With one player the pane is centred whichever side they are on; with two,
	-- each gets their own half.
	local centre
	if players == 2 then
		centre = _screen.cx + (EVAL_PANE_W + EVAL_PANE_GAP) * (pn == 1 and -0.5 or 0.5)
	else
		centre = _screen.cx - (EVAL_PANE_W + EVAL_PANE_GAP) * 0.5 + w * EVAL_ONE_PLAYER_NUDGE
	end

	return { x=centre - w/2, y=_screen.cy + EVAL_GRAPH_Y, w=w, h=h }
end


-- Reduces a song's samples to evenly spaced, smoothed points along the graph,
-- each {f, bpm, cut}, where f is the fraction across and cut marks a point that
-- begins a new run after a break in the readings.  Returns nil when there is
-- nothing worth drawing.
--
-- The span is the density graph's own: from the chart's first second (or zero,
-- whichever is lower) to the song's last.  Matching it is what puts a peak in
-- the line above the busy part of the chart that caused it.
local function GraphPoints(samples, pn)
	if #samples < 2 then return nil end

	local song = GAMESTATE:GetCurrentSong()
	local steps = GAMESTATE:GetCurrentSteps(SIDES[pn])
	if not song or not steps then return nil end

	local first = math.min(steps:GetTimingData():GetElapsedTimeFromBeat(0), 0)
	local span = song:GetLastSecond() - first
	if span <= 0 then return nil end

	-- Readings from before the song starts are dropped, even though the scale
	-- still runs from `first`.  The density graph skips every measure until a
	-- step occurs and the lifebar is offset to match, so a line running through
	-- the intro would be the only thing in the box claiming that time existed.
	--
	-- The cut is the start of the *measure* holding the first note, not the note
	-- itself: SL-Histogram.lua plots each measure at GetElapsedTimeFromBeat of
	-- its own first beat, so cutting at the note leaves the line starting up to
	-- one measure right of the bars.
	--
	-- Song-level, so it is the earliest note across every difficulty rather than
	-- this chart's own: on a song whose Beginner starts before its Expert, playing
	-- Expert draws a line reaching back into an intro this chart does not have.
	-- It is the same figure Graphs.lua offsets the lifebar by, so the two at least
	-- start together.  steps:GetNpsPerMeasure() would be exact, being what the
	-- histogram itself is built from; it is untried, an earlier attempt having
	-- failed for an unrelated reason.
	local timing = steps:GetTimingData()
	local firstBeat = timing:GetBeatFromElapsedTime(song:GetFirstSecond())
	local playFrom = timing:GetElapsedTimeFromBeat(math.floor(firstBeat / 4) * 4)

	local sum, count, when, opened, closed = {}, {}, {}, {}, {}
	for i = 1, HR_GRAPH_POINTS do sum[i], count[i], when[i] = 0, 0, 0 end
	for _, sample in ipairs(samples) do
		local f = (sample.t - first) / span
		if sample.t >= playFrom and f >= 0 and f <= 1 then
			local i = math.min(HR_GRAPH_POINTS, math.floor(f * HR_GRAPH_POINTS) + 1)
			sum[i], count[i] = sum[i] + sample.bpm, count[i] + 1
			when[i] = when[i] + f
			if opened[i] == nil then opened[i] = sample.t end
			closed[i] = sample.t
		end
	end

	-- An empty bucket is a gap in the readings, not a reading of zero, so it is
	-- dropped rather than dragging the line to the floor.  Whether it also breaks
	-- the line is decided on the samples' own clock: an empty bucket can just be
	-- bucket boundaries falling awkwardly on a short song.
	local raw, last = {}, nil
	for i = 1, HR_GRAPH_POINTS do
		if count[i] > 0 then
			raw[#raw+1] = {
				-- The mean position of this bucket's own samples, not the bucket's
				-- centre: centres inset the line by half a bucket at each end,
				-- which reads as the line failing to reach the graph it sits on.
				f = when[i] / count[i],
				bpm = sum[i] / count[i],
				cut = last ~= nil and (opened[i] - last) > HR_GRAPH_GAP,
			}
			last = closed[i]
		end
	end
	if #raw < 2 then return nil end
	if HR_GRAPH_SMOOTH < 2 then return raw end

	-- The moving average does not reach across a break: averaging the far side of
	-- a gap into the near side would invent a slope out of missing data.
	local half = math.floor(HR_GRAPH_SMOOTH / 2)
	local out = {}
	for i = 1, #raw do
		local total, n = 0, 0
		for j = i, math.max(1, i - half), -1 do
			if j < i and raw[j+1].cut then break end
			total, n = total + raw[j].bpm, n + 1
		end
		for j = i + 1, math.min(#raw, i + half) do
			if raw[j].cut then break end
			total, n = total + raw[j].bpm, n + 1
		end
		out[i] = { f=raw[i].f, bpm=total / n, cut=raw[i].cut }
	end
	return out
end


-- Everything the evaluation graph needs for one player, or nil when that side
-- has nothing to show.  The scale comes from the readings themselves, so the
-- labels are what say whether this was a warmup or a wall.
local function EvalPlot(pn)
	local samples = state[pn].samples
	local pts = GraphPoints(samples, pn)
	if pts == nil then return nil end

	-- This player's own look, or the defaults. Thickness is one number feeding
	-- the mitre below, so a profile's multiplier holds at every slope rather
	-- than only on the flat.
	local style = ProfileStyle(pn)
	local lineColor, thickness = style.color, style.thickness

	-- From the plotted points rather than the raw samples, so the labels describe
	-- the line that is actually drawn: anything trimmed off the intro is not part
	-- of what the reader can see.
	local lo, hi, sum = pts[1].bpm, pts[1].bpm, 0
	for _, p in ipairs(pts) do
		lo = math.min(lo, p.bpm)
		hi = math.max(hi, p.bpm)
		sum = sum + p.bpm
	end
	local mean = sum / #pts

	-- Headroom, so the peak does not sit on the box's edge. A flat song would
	-- divide by zero otherwise, so give it an arbitrary band to sit in.
	local pad = (hi - lo) * HR_GRAPH_PAD
	if pad <= 0 then pad = 1 end
	local bottom, top = lo - pad, hi + pad

	local box = EvalGraphBox(pn)
	local function yOf(bpm)
		return box.y + box.h * (1 - (bpm - bottom) / (top - bottom))
	end

	-- Ribbon geometry.  Offsetting each point straight up and down gives the
	-- strip a constant *vertical* extent, so what you see is 2*T*cos(slope):
	-- full width where the line is flat, a hairline where it climbs.  Offset
	-- along the vertex normal instead, lengthened at each join by 1/cos of the
	-- half-angle (a mitre) so consecutive quads meet flush rather than leaving
	-- a notch on the outside of every bend.
	local function segNormal(a, b)
		local dx, dy = b.x - a.x, b.y - a.y
		local len = math.sqrt(dx * dx + dy * dy)
		if len == 0 then return nil end
		return -dy / len, dx / len
	end

	-- x rises across the whole plot, so every segment normal points the same
	-- way and the strip cannot fold over on itself.
	local function offsets(run)
		for i, p in ipairs(run) do
			local ax, ay, bx, by
			if i > 1 then ax, ay = segNormal(run[i - 1], p) end
			if i < #run then bx, by = segNormal(p, run[i + 1]) end

			local nx, ny = ax or bx, ay or by
			if ax and bx then
				nx, ny = ax + bx, ay + by
				local len = math.sqrt(nx * nx + ny * ny)
				if len == 0 then
					nx, ny = ax, ay
				else
					nx, ny = nx / len, ny / len
					-- Capped, or a hairpin would throw a spike across the box.
					local d = math.max(nx * ax + ny * ay, 0.25)
					nx, ny = nx / d, ny / d
				end
			end
			-- A single point with no neighbour has no direction to be normal
			-- to; up and down is as good as anything.
			p.nx = (nx or 0) * thickness
			p.ny = (ny or 1) * thickness
		end
	end

	local verts = {}
	local function emit(p, alpha)
		local c = { lineColor[1], lineColor[2], lineColor[3], alpha }
		verts[#verts+1] = { {p.x - p.nx, p.y - p.ny, 0}, c }
		verts[#verts+1] = { {p.x + p.nx, p.y + p.ny, 0}, c }
	end

	-- Split at the gaps before measuring anything: a mitre is the average of the
	-- two segments meeting at a point, and the point across a gap is not one of
	-- them.
	local runs, cur = {}, {}
	for _, p in ipairs(pts) do
		if p.cut and #cur > 0 then
			runs[#runs+1] = cur
			cur = {}
		end
		cur[#cur+1] = { x = box.x + p.f * box.w, y = yOf(p.bpm) }
	end
	if #cur > 0 then runs[#runs+1] = cur end

	for i, run in ipairs(runs) do
		offsets(run)
		-- A quad strip is one continuous run, so a break is drawn by bridging it
		-- with fully transparent quads rather than by starting a second actor.
		if i > 1 then
			local prev = runs[i - 1]
			emit(prev[#prev], 0)
			emit(run[1], 0)
		end
		for _, p in ipairs(run) do emit(p, lineColor[4]) end
	end

	-- Min and max define the scale and always show. The mean is the first thing
	-- to go when there is no room for it.
	local labels = {
		{ y=yOf(hi), text=string.format("%d", math.floor(hi + 0.5)), color=lineColor },
		{ y=yOf(lo), text=string.format("%d", math.floor(lo + 0.5)), color=lineColor },
	}
	-- The mean's label is pushed off its true height when it would collide,
	-- rather than dropped: the rule across the box is what says where the mean
	-- actually sits, so the number only has to stay readable and adjacent. It is
	-- always pushed inward, away from whichever of min or max it was crowding.
	local meanY = yOf(mean)
	local gap = CAP_HEIGHT * HR_LABEL_ZOOM + HR_LABEL_PAD * 2
	local labelY = meanY
	if labelY - labels[1].y < gap then labelY = labels[1].y + gap end
	if labels[2].y - labelY < gap then labelY = labels[2].y - gap end

	-- Unless min and max are themselves so close that there is no room between.
	if labels[2].y - labels[1].y >= gap * 2 then
		labels[#labels+1] = { y=labelY, text=string.format("%d", math.floor(mean + 0.5)), color=lineColor }
	end

	-- The rule is drawn whether or not the label beside it survived, since it is
	-- the reference the line is read against.
	-- The mean rule takes the line's hue at the default's alpha, so one profile
	-- key drives all three pieces without naming each.
	local meanColor = { lineColor[1], lineColor[2], lineColor[3], HR_MEAN_LINE[4] }
	return { box=box, verts=verts, labels=labels, meanY=meanY, meanColor=meanColor }
end


-- One reading written at the height it sits at, backed by a quad because the
-- density bars run underneath.
local function EvalLabel(index)
	return Def.ActorFrame{
		PlotCommand=function(self, plot)
			local label = plot.labels[index]
			self:visible(label ~= nil)
			if label == nil then return end
			self:xy(plot.box.x + HR_LABEL_INSET, label.y)
			self:playcommand("Write", label)
		end,

		Def.Quad{
			InitCommand=function(self) self:halign(0):diffuse(HR_LABEL_BG) end,
			WriteCommand=function(self, label)
				local w = DIGIT_WIDTH * HR_LABEL_ZOOM * #label.text
				self:zoomto(w + HR_LABEL_PAD * 2, CAP_HEIGHT * HR_LABEL_ZOOM + HR_LABEL_PAD * 2)
			end,
		},

		LoadFont("Wendy/_wendy monospace numbers")..{
			InitCommand=function(self)
				self:halign(0):valign(0.5):zoom(HR_LABEL_ZOOM):diffuse(HR_LABEL_COLOR)
			end,
			WriteCommand=function(self, label)
				-- Same ink correction the panel readout needs; see INK_OFFSET.
				self:diffuse(label.color or HR_LABEL_COLOR)
				self:settext(label.text)
				self:y(-INK_OFFSET * HR_LABEL_ZOOM)
				self:x(HR_LABEL_PAD)
			end,
		},
	}
end


-- The corner heart.  It reads the same files the panels do, so it reports what
-- would actually be drawn rather than what gotempo thinks it is connected to: a
-- strap that is connected but sending nothing leaves this dim, which is the
-- honest answer.
local function StatusHeart(pn)
	local live, pulseAt = false, nil

	return Def.ActorFrame{
		InitCommand=function(self)
			local inset = STATUS_HEART_MARGIN + STATUS_HEART_SIZE / 2
			self:xy(pn == 1 and inset or _screen.w - inset,
			        _screen.h - STATUS_HEART_MARGIN - STATUS_HEART_SIZE / 2)
			-- Shown from the first poll on, once there is something to report.
			self:visible(false)
		end,
		ModuleCommand=function(self)
			self:stoptweening()
			if STATUS_HEART then self:queuecommand("Beat") end
		end,
		BeatCommand=function(self)
			local bpm = ReadHeartRate(HR_FILES[pn])
			live = bpm ~= nil
			self:visible(pn == 1 or live or GAMESTATE:IsSideJoined(SIDES[pn]))

			if bpm == nil then
				self:stopeffect()
				pulseAt = nil
			elseif PULSE and bpm ~= pulseAt then
				self:pulse():effectmagnitude(1, PULSE_MAGNITUDE, 0):effectperiod(60 / bpm)
				pulseAt = bpm
			end

			self:GetChild("Icon"):diffuse(live and STATUS_HEART_LIVE or STATUS_HEART_DEAD)
			self:sleep(POLL_SECONDS):queuecommand("Beat")
		end,

		Def.Sprite{
			Name="Icon",
			Texture=ICON_TEXTURE,
			InitCommand=function(self) self:zoomto(STATUS_HEART_SIZE, STATUS_HEART_SIZE) end,
		},
	}
end


-- Which side pressed, or nil for an event that belongs to neither.
local function EventSide(event)
	for pn = 1, 2 do
		if tostring(event.PlayerNumber) == SIDES[pn] then return pn end
	end
	return nil
end


-- The evaluation screen takes input callbacks (the theme registers four of its
-- own), and the only menu buttons it consumes are left and right, for cycling
-- the panes.  So a module can listen without touching a theme file and without
-- taking a button out from under anything.  The callback returns false, like
-- the theme's, so the screen still sees the press.
local function WatchToggle()
	local screen = SCREENMAN:GetTopScreen()
	if screen == nil or screen.AddInputCallback == nil then return end

	screen:AddInputCallback(function(event)
		if event == nil or event.type ~= "InputEventType_FirstPress" then return false end
		if event.GameButton ~= HR_GRAPH_TOGGLE then return false end

		local pn = EventSide(event)
		if pn == nil then return false end

		graphShown[pn] = not graphShown[pn]
		-- A broadcast rather than a playcommand: this has to reach actors two
		-- frames down, and only messages are guaranteed to recurse.
		MESSAGEMAN:Broadcast("GotempoGraphToggled")
		return false
	end)
end


-- ── the picker's screen ─────────────────────────────────────────────────────
--
-- Two panels, one per side, each driven by that side's own controller.  Whose
-- pick this is stops being a question the menu has to ask: it is whoever pressed
-- the button, which the input event already says.  An earlier single-panel
-- version carried a P1/P2 selector and a mode chosen when it opened, and every
-- bug in it came from those two disagreeing.
--
-- Changes are held per side and written only on Save, so a pick can be undone by
-- leaving, and so browsing the list does not make gotempo connect and reconnect
-- behind the menu.

local PANEL_W = 400
local PANEL_GAP = 22
local PANEL_H = 392

-- Every colour here is opaque, and the dim variants are mixed against the panel
-- background by hand rather than left to alpha.  Translucent text is harder to
-- read than the same colour darkened, in every case, and a whole frame faded out
-- with diffusealpha is unreadable.
local PICKER_BG = color("#0B0F14")
local PICKER_RULE = color("#2B2F33")
local PICKER_TEXT = color("#E0E0E0")
local PICKER_DIM = color("#9AA0A4")
local PICKER_OK = color("#13BE74")
local PICKER_BAD = color("#D35612")

-- A side that has finished is dimmed, not faded: same hues, darker, still
-- legible from across the machine so the other player can see it is done.
local PICKER_DONE = {
	text = color("#71777B"),
	dim  = color("#5A6064"),
	ok   = color("#0E7048"),
	bad  = color("#7C3510"),
}

-- A third hue, deliberately.  Green and red are the two status colours and are
-- the pair most often confused, so the cursor takes neither; the marker and the
-- bar behind the row mean colour is never carrying it alone anyway.
local PICKER_SEL = color("#4DB8FF")
local PICKER_SEL_BAR = color("#183143")	-- the selection blue mixed into the background

-- Every module's actors for a screen are siblings under one frame, so draw order
-- decides which sits on top and the default is load order, which is the Modules/
-- directory listing.
local PICKER_DRAW_ORDER = 200
local PICKER_GUARD = 0.1		-- how often the input redirect is reasserted

-- Panel-local layout, written out rather than derived: deriving it put one row
-- on top of another the moment a line was added between them.
local P_HEADER_Y = -178
local P_STATUS_Y = -146
local P_STATUS_SUB_Y = -126
local P_RULE_TOP_Y = -108
-- List rows are taller, so they start lower: sharing one origin put the first
-- one's top edge exactly on the rule above it.
local NAV_ROWS_Y = -86
local LIST_ROWS_Y = -76
local P_RULE_BOT_Y = 152
local P_FOOTER_Y = 172
local P_GUTTER = 18			-- fixed, so the marker never shifts the text

local NAV_ROW_H = 30
local NAV_VISIBLE = 8
local LIST_ROW_H = 44
local LIST_VISIBLE = 5



local picker = { open = false }
local side = {}


local function ChoiceIndex(list, value, fallback)
	for i, v in ipairs(list) do
		if tostring(v):upper() == tostring(value):upper() then return i end
	end
	return fallback
end


-- ── per-side state ──────────────────────────────────────────────────────────

local function SideRows(st)
	local rows = {}
	rows[#rows+1] = { action = "choose", name = st.device and "Change strap" or "Choose a strap" }
	if st.device ~= nil then
		rows[#rows+1] = { action = "remove", name = "Remove strap" }
	end
	rows[#rows+1] = { adjust = "color", name = "Line colour" }
	rows[#rows+1] = { adjust = "thickness", name = "Line thickness" }
	rows[#rows+1] = { action = "save", name = "Save and exit" }
	-- Named for what it will actually do, so a player who changed nothing is not
	-- told they are discarding.
	rows[#rows+1] = { action = "exit", name = st.dirty and "Back without saving" or "Exit" }
	return rows
end

local function ShowNav(st)
	st.mode = "nav"
	st.rows = SideRows(st)
	st.cursor = math.min(st.cursor or 1, #st.rows)
	st.first = 1
end

local function ShowList(st)
	st.mode = "list"
	st.cursor, st.first = 1, 1
	st.rows = PickerRows(picker.devices or {}, picker.owners or {}, st.device)
	st.rows[#st.rows+1] = { action = "rescan", name = "Scan again" }
	st.rows[#st.rows+1] = { action = "back", name = "Back" }
	for i, row in ipairs(st.rows) do
		if not row.divider then st.cursor = i break end
	end
end


-- The scan belongs to the machine, not to a side.  Whoever asks first starts it
-- and both lists fill at once; a side opening the list afterwards gets the
-- result straight away, with no second scan and no second wait.
local function BeginScan(st)
	if picker.devices ~= nil and not picker.scanning then
		ShowList(st)
		return
	end
	st.mode = "scanning"
	st.rows, st.cursor, st.first = {}, 1, 1
	if not picker.scanning then
		picker.scanning = true
		picker.waitUntil = secondsOfDay() + SCAN_WAIT
		RequestScan()
	end
end


local function FinishSide(st, how)
	st.finished = how
	st.mode = "done"
	st.rows, st.cursor = {}, 1
end

local function SaveSide(st)
	WriteProfileSettings(st.pn, st)
	st.dirty = false
	FinishSide(st, "saved")
end


-- Everyone who could still act.  A side with no profile has nowhere to save, so
-- it counts as finished from the start rather than blocking the close.
local function PickerAllDone()
	for _, st in pairs(side) do
		if st.profile and st.finished == nil then return false end
	end
	return true
end


-- ── opening and closing ─────────────────────────────────────────────────────

local function PickerRedirect(on)
	if SCREENMAN == nil then return end
	for player in ivalues(PlayerNumber) do
		SCREENMAN:set_input_redirected(player, on)
	end
end


local function PickerOpen()
	if picker.open then return end

	side = {}
	local any = false
	for pn = 1, 2 do
		if GAMESTATE:IsSideJoined(SIDES[pn]) then
			local dir = PROFILEMAN and PROFILEMAN:GetProfileDir(PROFILE_SLOTS[pn])
			local st = { pn = pn, profile = dir ~= nil and #dir > 0, cursor = 1, first = 1, dirty = false }

			if st.profile then
				local style = ProfileStyle(pn)
				st.device = ProfileDevice(pn)
				st.color = ChoiceIndex(HR_COLOR_CHOICES, style.colorHex or HR_COLOR_CHOICES[1], 1)
				st.thickness = ChoiceIndex(HR_THICKNESS_CHOICES,
					style.thickness / HR_GRAPH_THICKNESS, ChoiceIndex(HR_THICKNESS_CHOICES, 1.0, 3))
				ShowNav(st)
				any = true
			else
				FinishSide(st, "noprofile")
			end
			side[pn] = st
		end
	end
	if not any then return end

	picker.open = true
	picker.devices, picker.owners, picker.scanning, picker.waitUntil = nil, nil, false, nil
	PickerRedirect(true)

	-- The wheel may still be coasting from the press that opened the menu.
	local screen = SCREENMAN:GetTopScreen()
	if screen ~= nil and screen.GetMusicWheel ~= nil then
		screen:GetMusicWheel():Move(0)
	end
end


local function PickerClose()
	picker.open = false
	PickerRedirect(false)
	CancelScan()
end


-- ── input ───────────────────────────────────────────────────────────────────

local function Adjust(st, row, delta)
	if row.adjust == "color" then
		st.color = ((st.color - 1 + delta) % #HR_COLOR_CHOICES) + 1
	elseif row.adjust == "thickness" then
		st.thickness = ((st.thickness - 1 + delta) % #HR_THICKNESS_CHOICES) + 1
	else
		return
	end
	st.dirty = true
	ShowNav(st)	-- the exit row is named after this flag
end


local function Confirm(st)
	local row = st.rows[st.cursor]
	if row == nil then return end

	if row.action == "choose" then
		BeginScan(st)
	elseif row.action == "remove" then
		st.device, st.dirty = nil, true
		ShowNav(st)
	elseif row.action == "save" then
		SaveSide(st)
	elseif row.action == "exit" then
		FinishSide(st, "exited")
	elseif row.action == "rescan" then
		picker.devices = nil
		BeginScan(st)
	elseif row.action == "back" then
		ShowNav(st)
	elseif row.mac ~= nil then
		st.device, st.dirty = row.mac, true
		ShowNav(st)
	end
end


local function Move(st, delta)
	if #st.rows == 0 then return end
	local i = st.cursor
	for _ = 1, #st.rows do
		i = ((i - 1 + delta) % #st.rows) + 1
		if not st.rows[i].divider then
			st.cursor = i
			return
		end
	end
end


local function PickerInput(event)
	if not picker.open then return false end
	if event == nil or event.type ~= "InputEventType_FirstPress" then return true end

	local pn = EventSide(event)
	local st = pn and side[pn]
	if st == nil then return true end

	local b = event.GameButton

	-- A finished side is inert except for changing its mind, which beats making
	-- someone close and reopen the whole menu because they picked the wrong H10.
	if st.finished ~= nil then
		if b == "Start" and st.profile then
			st.finished = nil
			ShowNav(st)
			MESSAGEMAN:Broadcast("GotempoPickerChanged")
		end
		return true
	end

	if b == "MenuUp" then
		Move(st, -1)
	elseif b == "MenuDown" then
		Move(st, 1)
	elseif b == "MenuLeft" or b == "MenuRight" then
		local row = st.rows[st.cursor]
		if row ~= nil and row.adjust ~= nil then
			Adjust(st, row, b == "MenuRight" and 1 or -1)
		end
	elseif b == "Start" then
		if st.mode == "nav" or st.mode == "list" then
			Confirm(st)
		elseif st.mode == "empty" or st.mode == "nogotempo" then
			picker.devices = nil
			BeginScan(st)
		end
	elseif b == "Back" or b == "Select" then
		-- Back never acts at the top level. It parks the cursor on Save and exit
		-- instead, so leaving without saving takes deliberate navigation and the
		-- reflex press lands on the safe outcome.
		if st.mode == "nav" then
			for i, row in ipairs(st.rows) do
				if row.action == "save" then st.cursor = i end
			end
		else
			ShowNav(st)
		end
	end

	if PickerAllDone() then PickerClose() end
	MESSAGEMAN:Broadcast("GotempoPickerChanged")
	return true
end


-- ── polling ─────────────────────────────────────────────────────────────────

local function PickerPoll()
	if not picker.scanning then return end

	local devices = ReadDevices()
	if devices ~= nil then
		picker.devices = devices
		picker.owners = StrapOwners()
		picker.scanning = false
		CancelScan()
		for _, st in pairs(side) do
			if st.mode == "scanning" then
				if #devices == 0 then st.mode = "empty" else ShowList(st) end
			end
		end
	elseif secondsOfDay() > (picker.waitUntil or 0) then
		picker.scanning = false
		CancelScan()
		for _, st in pairs(side) do
			if st.mode == "scanning" then st.mode = "nogotempo" end
		end
	end
end


-- ── what a panel says ───────────────────────────────────────────────────────

-- The colour a side draws in: its own while it can still act, the dim set once
-- it is finished.
local function Ink(st, which)
	if st ~= nil and st.finished ~= nil and PICKER_DONE[which] ~= nil then
		return PICKER_DONE[which]
	end
	if which == "dim" then return PICKER_DIM end
	if which == "ok" then return PICKER_OK end
	if which == "bad" then return PICKER_BAD end
	return PICKER_TEXT
end


local function PickerPanelHeader(st)
	local name = "P" .. st.pn
	if st.profile and PROFILEMAN ~= nil then
		local profile = PROFILEMAN:GetProfile(SIDES[st.pn])
		if profile ~= nil then name = name .. " · " .. profile:GetDisplayName() end
	end
	if st.dirty then name = name .. " · unsaved" end
	return name
end


-- The strap this side will have, and whether anything is coming from it.
--
-- The reading only belongs beside a strap that is actually saved: while a pick
-- is pending, hr.txt still carries whatever gotempo is connected to now, and
-- showing that number under a different strap's name would be a lie.
local function PickerPanelStatus(st)
	if not st.profile then
		return { mark = "×", text = "No profile loaded", ink = "bad" }
	end
	if st.device == nil then
		return { mark = "×", text = "No strap selected", ink = "bad" }
	end

	local name = st.device
	for _, d in ipairs(picker.devices or {}) do
		if d.mac:upper() == st.device:upper() then name = d.name end
	end

	if st.dirty then
		return { mark = "•", text = name, ink = "text", sub = "saves on exit" }
	end
	local bpm = ReadHeartRate(HR_FILES[st.pn])
	if bpm ~= nil then
		return { mark = "•", text = name, ink = "ok", sub = bpm .. " bpm" }
	end
	return { mark = "·", text = name, ink = "dim", sub = "connecting…" }
end


local function PickerPanelFooter(st)
	if st.finished == "saved" then return "Saved" end
	if st.finished == "exited" then return "Exited without saving" end
	if st.finished ~= nil then return "" end
	if st.mode == "scanning" then return "BACK cancel" end
	if st.mode == "empty" or st.mode == "nogotempo" then return "START retry     BACK back" end
	if st.mode == "list" then return "START pick      BACK back" end
	return "START select"
end


local function PickerPanelHint(st)
	if st.mode == "scanning" then return "Scanning for straps…" end
	if st.mode == "empty" then return "No straps found.\nPut the strap on and make sure\nit is not connected elsewhere." end
	if st.mode == "nogotempo" then return "gotempo is not running." end
	return nil
end


-- The value shown on an adjuster row.
local function RowValue(st, row)
	if row.adjust == "color" then return HR_COLOR_CHOICES[st.color] end
	if row.adjust == "thickness" then return string.format("%.1f", HR_THICKNESS_CHOICES[st.thickness]) end
	return nil
end


-- ── drawing ─────────────────────────────────────────────────────────────────

local function PickerPanelRow(pn, index)
	return Def.ActorFrame{
		DrawCommand=function(self)
			local st = side[pn]
			local row = st and st.rows[(st.first or 1) + index - 1]
			self:visible(row ~= nil)
			if row == nil then return end

			local list = (st.mode == "list")
			local h = list and LIST_ROW_H or NAV_ROW_H
			self:y((list and LIST_ROWS_Y or NAV_ROWS_Y) + (index - 1) * h)
			self:playcommand("Fill", { st = st, row = row, at = (st.first or 1) + index - 1 })
		end,

		Def.Quad{
			Name="Bar",
			InitCommand=function(self) self:zoomto(PANEL_W - 24, NAV_ROW_H - 4):diffuse(PICKER_SEL_BAR) end,
			FillCommand=function(self, p)
				self:visible(not p.row.divider and p.at == p.st.cursor)
				local h = (p.st.mode == "list") and LIST_ROW_H or NAV_ROW_H
				self:zoomto(PANEL_W - 24, h - 4)
			end,
		},
		Def.Quad{
			Name="Rule",
			InitCommand=function(self) self:zoomto(PANEL_W - 40, 1):diffuse(PICKER_RULE) end,
			FillCommand=function(self, p) self:visible(p.row.divider == true) end,
		},
		LoadFont("Common Normal")..{
			Name="Marker",
			InitCommand=function(self)
				self:halign(0):zoom(0.6):x(-PANEL_W/2 + 14):settext("›")
			end,
			FillCommand=function(self, p)
				self:visible(not p.row.divider and p.at == p.st.cursor)
				self:diffuse(PICKER_SEL)
				self:y((p.st.mode == "list") and -10 or 0)
			end,
		},
		LoadFont("Common Normal")..{
			Name="Name",
			-- Indented past a gutter the marker lives in, so selecting a row
			-- never shifts its text sideways.
			InitCommand=function(self)
				self:halign(0):zoom(0.7):x(-PANEL_W/2 + 14 + P_GUTTER):maxwidth((PANEL_W - 150) / 0.7)
			end,
			FillCommand=function(self, p)
				self:visible(not p.row.divider)
				if p.row.divider then return end
				self:settext(p.row.name)
				self:diffuse(p.at == p.st.cursor and PICKER_SEL or Ink(p.st, "text"))
				self:y((p.st.mode == "list") and -10 or 0)
			end,
		},
		LoadFont("Common Normal")..{
			Name="Value",
			InitCommand=function(self) self:halign(1):zoom(0.65):x(PANEL_W/2 - 16) end,
			FillCommand=function(self, p)
				local value = RowValue(p.st, p.row)
				self:visible(value ~= nil)
				if value == nil then return end
				self:settext("‹ " .. value .. " ›")
				self:diffuse(p.at == p.st.cursor and PICKER_SEL or Ink(p.st, "dim"))
			end,
		},
		Def.Quad{
			Name="Swatch",
			InitCommand=function(self) self:zoomto(12, 12):x(PANEL_W/2 - 118) end,
			FillCommand=function(self, p)
				self:visible(p.row.adjust == "color")
				if p.row.adjust == "color" then
					self:diffuse(color(HR_COLOR_CHOICES[p.st.color]))
				end
			end,
		},
		LoadFont("Common Normal")..{
			Name="Sub",
			InitCommand=function(self)
				self:halign(0):zoom(0.52):x(-PANEL_W/2 + 14 + P_GUTTER):y(10)
				self:maxwidth((PANEL_W - 40) / 0.52)
			end,
			FillCommand=function(self, p)
				local row = p.row
				local show = (p.st.mode == "list") and row.mac ~= nil
				self:visible(show)
				if not show then return end
				self:diffuse(Ink(p.st, "dim"))
				local text = row.mac
				if row.yours then
					text = text .. "  ·  yours"
				elseif row.owners ~= nil then
					text = text .. "  ·  " .. table.concat(row.owners, ", ")
				end
				self:settext(text)
			end,
		},
	}
end


local function PickerPanel(pn)
	local af = Def.ActorFrame{
		DrawCommand=function(self)
			local st = side[pn]
			self:visible(st ~= nil)
			if st == nil then return end

			-- Keep the cursor inside the window, scrolling only when it leaves.
			local visible = (st.mode == "list") and LIST_VISIBLE or NAV_VISIBLE
			st.first = st.first or 1
			if st.cursor < st.first then st.first = st.cursor end
			if st.cursor > st.first + visible - 1 then st.first = st.cursor - visible + 1 end
		end,

		Def.Quad{
			InitCommand=function(self) self:zoomto(PANEL_W, PANEL_H):diffuse(PICKER_BG) end,
		},
		LoadFont("Common Normal")..{
			Name="Header",
			InitCommand=function(self) self:zoom(0.7):y(P_HEADER_Y):diffuse(PICKER_DIM) end,
			DrawCommand=function(self)
				local st = side[pn]
				if st == nil then return end
				self:settext(PickerPanelHeader(st)):diffuse(Ink(st, "dim"))
			end,
		},
		LoadFont("Common Normal")..{
			Name="Status",
			InitCommand=function(self)
				self:zoom(0.78):y(P_STATUS_Y):maxwidth((PANEL_W - 40) / 0.78)
			end,
			DrawCommand=function(self)
				local st = side[pn]
				if st == nil then return end
				local status = PickerPanelStatus(st)
				self:settext(status.mark .. "  " .. status.text):diffuse(Ink(st, status.ink))
			end,
		},
		LoadFont("Common Normal")..{
			Name="StatusSub",
			InitCommand=function(self) self:zoom(0.6):y(P_STATUS_SUB_Y):diffuse(PICKER_DIM) end,
			DrawCommand=function(self)
				local st = side[pn]
				local status = st and PickerPanelStatus(st)
				self:visible(status ~= nil and status.sub ~= nil)
				if status == nil then return end
				self:settext(status.sub or ""):diffuse(Ink(st, "dim"))
			end,
		},
		Def.Quad{
			InitCommand=function(self) self:zoomto(PANEL_W - 40, 1):y(P_RULE_TOP_Y):diffuse(PICKER_RULE) end,
		},
		Def.Quad{
			InitCommand=function(self) self:zoomto(PANEL_W - 40, 1):y(P_RULE_BOT_Y):diffuse(PICKER_RULE) end,
		},
		LoadFont("Common Normal")..{
			Name="Hint",
			InitCommand=function(self)
				self:zoom(0.6):y(NAV_ROWS_Y + 40):diffuse(PICKER_DIM):maxwidth((PANEL_W - 40) / 0.6)
			end,
			DrawCommand=function(self)
				local st = side[pn]
				local hint = st and PickerPanelHint(st)
				self:visible(hint ~= nil)
				if hint ~= nil then self:settext(hint):diffuse(Ink(st, "dim")) end
			end,
		},
		LoadFont("Common Normal")..{
			Name="Footer",
			InitCommand=function(self) self:zoom(0.6):y(P_FOOTER_Y):diffuse(PICKER_DIM) end,
			DrawCommand=function(self)
				local st = side[pn]
				if st == nil then return end
				self:settext(PickerPanelFooter(st))
				self:diffuse(st.finished == "saved" and Ink(st, "ok") or Ink(st, "dim"))
			end,
		},
	}
	for i = 1, NAV_VISIBLE do af[#af+1] = PickerPanelRow(pn, i) end
	return af
end


-- Drawn above everything, like the rest of this module, so it needs no help from
-- the screen underneath and cannot be covered by it.
local function Picker()
	local af = Def.ActorFrame{
		InitCommand=function(self) self:xy(_screen.cx, _screen.cy):visible(false) end,
		ModuleCommand=function(self)
			-- Leaving the screen with the picker up must not leave input
			-- redirected, or the next screen is dead to every button.
			if picker.open then PickerClose() end
			picker.pending = nil
			self:visible(false)

			-- Registered per screen instance, so each visit gets exactly one.
			local screen = SCREENMAN:GetTopScreen()
			if screen ~= nil and screen.AddInputCallback ~= nil then
				screen:AddInputCallback(PickerInput)
			end
		end,
		GotempoPickerOpenMessageCommand=function(self)
			-- Not opened here. The sort menu's own DirectInputToEngine is queued
			-- behind this and un-redirects input on its way out, so a redirect
			-- set now would simply be undone. The guard below picks this up on
			-- its next beat, by which time that has run.
			picker.pending = true
		end,
		OpenCommand=function(self)
			picker.pending = nil
			PickerOpen()
			self:visible(picker.open)
			if picker.open then self:playcommand("Draw") end
		end,
		GotempoPickerChangedMessageCommand=function(self)
			self:visible(picker.open)
			self:playcommand("Draw")
		end,
		PollCommand=function(self)
			if not picker.open then return end
			PickerPoll()
			self:playcommand("Draw")
		end,
	}

	-- One panel per side, on that side's half of the screen. A lone player keeps
	-- their own side rather than being centred, which says whose it is without
	-- needing a label.
	for pn = 1, 2 do
		local panel = PickerPanel(pn)
		panel.InitCommand = function(self)
			self:x(pn == 1 and -(PANEL_W + PANEL_GAP) / 2 or (PANEL_W + PANEL_GAP) / 2)
		end
		af[#af+1] = panel
	end

	-- Two independent chains, each on its own actor. sleep() queues per actor,
	-- so running both on the frame above would make each wait on the other.
	af[#af+1] = Def.Actor{
		Name="Clock",
		ModuleCommand=function(self) self:stoptweening():queuecommand("Tick") end,
		TickCommand=function(self)
			self:GetParent():playcommand("Poll")
			self:sleep(POLL_SECONDS):queuecommand("Tick")
		end,
	}
	af[#af+1] = Def.Actor{
		Name="Guard",
		ModuleCommand=function(self) self:stoptweening():queuecommand("Beat") end,
		BeatCommand=function(self)
			if picker.pending ~= nil then
				self:GetParent():playcommand("Open")
			elseif picker.open then
				-- Reasserted rather than set once: anything else on the screen
				-- can hand input back, and a stray call mid-pick would put the
				-- music wheel under a menu the player thinks is modal.
				PickerRedirect(true)
			end
			self:sleep(PICKER_GUARD):queuecommand("Beat")
		end,
	}
	return af
end


-- The sort menu is a supported extension point: custom_functions is declared on
-- the SortMenu actor and dispatched as the last case of its Start handler, in
-- stock Simply Love as well as this fork.  So the entry costs no theme edit.
-- ArrowCloud.lua does the same thing, and this follows its shape.
local function InstallSortMenuEntry(self)
	local top = SCREENMAN:GetTopScreen()
	if top == nil or top:GetName() ~= "ScreenSelectMusic" then return end

	local overlay = top:GetChild("Overlay")
	local sortmenu = overlay and overlay:GetChild("SortMenu")
	if sortmenu == nil then
		-- The overlay is not built yet; a module's ModuleCommand can beat it.
		self:sleep(0.15):queuecommand("InstallSortMenu")
		return
	end

	sortmenu.custom_functions = sortmenu.custom_functions or {}
	sortmenu.custom_functions[SORTMENU_BOTTOM] = function(event)
		local screen = SCREENMAN:GetTopScreen()
		local ov = screen and screen:GetChild("Overlay")
		if ov ~= nil then ov:queuecommand("DirectInputToEngine") end
		MESSAGEMAN:Broadcast("GotempoPickerOpen", { PlayerNumber = event and event.PlayerNumber })
	end

	if sortmenu.wheel_options == nil then return end

	-- Prefer the Advanced submenu, where the other per-player logins live.
	local menu = sortmenu.wheel_options
	for _, option in ipairs(sortmenu.wheel_options) do
		if option[1] and option[1][2] == "CategoryAdvanced" and type(option[2]) == "table" then
			menu = option[2]
			break
		end
	end

	-- custom_functions is file-scope in the theme and survives screen changes,
	-- so this runs again on every visit and must not stack up entries.
	for _, option in ipairs(menu) do
		if option[1] and option[1][1] == SORTMENU_TOP and option[1][2] == SORTMENU_BOTTOM then
			return
		end
	end
	table.insert(menu, { { SORTMENU_TOP, SORTMENU_BOTTOM } })
end


local function EvalGraph()
	local af = Def.ActorFrame{
		ModuleCommand=function(self) WatchToggle() end,
	}
	for pn = 1, 2 do
		-- Whether this side has anything to draw at all, which the toggle must
		-- not override: an empty graph stays hidden however often it is pressed.
		local plotted = false

		af[#af+1] = Def.ActorFrame{
			ModuleCommand=function(self)
				-- Nothing to say when this side did not play, or wore no strap.
				local plot = nil
				if HR_GRAPH and GAMESTATE:IsSideJoined(SIDES[pn]) then
					plot = EvalPlot(pn)
				end
				plotted = plot ~= nil
				self:visible(plotted and graphShown[pn])
				if plot ~= nil then self:playcommand("Plot", plot) end
			end,
			GotempoGraphToggledMessageCommand=function(self)
				self:visible(plotted and graphShown[pn])
			end,

			Def.Quad{
				InitCommand=function(self) self:halign(0):diffuse(HR_MEAN_LINE) end,
				PlotCommand=function(self, plot)
					self:diffuse(plot.meanColor or HR_MEAN_LINE)
					self:xy(plot.box.x, plot.meanY):zoomto(plot.box.w, HR_MEAN_LINE_H)
				end,
			},

			Def.ActorMultiVertex{
				InitCommand=function(self)
					self:SetDrawState({Mode="DrawMode_QuadStrip"})
				end,
				PlotCommand=function(self, plot)
					self:SetNumVertices(#plot.verts):SetVertices(plot.verts)
				end,
			},

			EvalLabel(1),
			EvalLabel(2),
			EvalLabel(3),
		}
	end
	return af
end


local t = {}

-- The outer frame owns the poll for both panels: one timer reading both files
-- per tick, rather than two sleep chains drifting against each other.
t.ScreenGameplay = Def.ActorFrame{
	ModuleCommand=function(self)
		self:stoptweening()
		self:playcommand("Setup")
		self:queuecommand("Tick")
	end,

	TickCommand=function(self)
		WritePlayers()
		local second = GAMESTATE:GetCurMusicSeconds()
		for pn = 1, 2 do
			local s = state[pn]
			local stamp
			s.bpm, stamp = nil, nil
			if s.geo ~= nil then s.bpm, stamp = ReadHeartRate(s.file) end

			-- A stamp that has not moved means no reading arrived since the last
			-- poll. The panel keeps showing the last value, which is deliberate
			-- and harmless for a second or two on screen; the graph is a record,
			-- so it holds a stricter line and simply stops collecting.
			if stamp ~= nil and stamp == s.stamp then
				s.repeats = s.repeats + 1
			else
				s.repeats = 0
			end
			s.stamp = stamp

			local fresh = s.bpm ~= nil and s.repeats < HR_STALE_POLLS
			if HR_GRAPH and fresh and second ~= nil then
				s.samples[#s.samples+1] = { t=second, bpm=s.bpm }
			end
		end
		self:playcommand("Refresh")
		self:sleep(POLL_SECONDS):queuecommand("Tick")
	end,

	Panel(1),
	Panel(2),
}

-- The same publish loop with nothing to draw, for the screens either side of a
-- song.  Select-music is the one that matters: a strap takes a few seconds to
-- connect, so gotempo has to be told who is playing before the first note, not
-- as it arrives.  The evaluation screens keep the stamp alive between songs so
-- the straps are not released and reacquired every round.
local function PublishOnly()
	return Def.ActorFrame{
		ModuleCommand=function(self)
			self:stoptweening()
			self:queuecommand("Tick")
		end,
		TickCommand=function(self)
			WritePlayers()
			self:sleep(POLL_SECONDS):queuecommand("Tick")
		end,
	}
end

local function StatusHearts()
	return Def.ActorFrame{ StatusHeart(1), StatusHeart(2) }
end

t.ScreenSelectMusic = Def.ActorFrame{
	-- Above the other modules on this screen: they are all siblings under one
	-- frame, and without this the picker draws under whichever module loaded
	-- after gotempo.
	InitCommand=function(self) self:draworder(PICKER_DRAW_ORDER) end,
	ModuleCommand=function(self) self:queuecommand("InstallSortMenu") end,
	InstallSortMenuCommand=function(self) InstallSortMenuEntry(self) end,

	PublishOnly(),
	StatusHearts(),
	Picker(),
}
for _, screen in ipairs(STATUS_HEART_SCREENS) do
	if t[screen] == nil then t[screen] = StatusHearts() end
end
t.ScreenEvaluation = PublishOnly()
t.ScreenEvaluationNonstop = PublishOnly()
t.ScreenEvaluationSummary = PublishOnly()

-- The normal per-song evaluation screen gets the heart-rate line as well as the
-- publish loop.  Course modes are left alone: their density graph is assembled
-- from several songs by a different code path, so one song's samples would not
-- line up with it.
t.ScreenEvaluationStage = Def.ActorFrame{
	PublishOnly(),
	EvalGraph(),
}

return t
