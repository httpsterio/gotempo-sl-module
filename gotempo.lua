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
local HR_FILES = {
	THEME:GetCurrentThemeDirectory() .. "Modules/hr.txt",
	THEME:GetCurrentThemeDirectory() .. "Modules/hr-p2.txt",
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
local PLAYERS_FILE = THEME:GetCurrentThemeDirectory() .. "Modules/players.txt"

-- Where a player names their strap, in their own profile, following the
-- convention ArrowCloud and GrooveStats already use:
--
--	[gotempo]
--	Device=24:AC:AC:18:41:CC
local PROFILE_INI = "gotempo.ini"
local PROFILE_SECTION = "gotempo"
local PROFILE_KEY = "Device"

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

-- Resolved relative to this module's own directory, not the theme root.
local ICON_TEXTURE = "heart (mipmaps).png"

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
	{ bpm=nil, pulseBpm=nil, geo=nil, file=HR_FILES[1] },
	{ bpm=nil, pulseBpm=nil, geo=nil, file=HR_FILES[2] },
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

	return value
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


-- Publishes who is playing.  Called on every tick rather than on screen entry:
-- the stamp is the payload, so a file that stops being rewritten is how gotempo
-- learns the game is gone.  Sides are reported even when they name no strap.
local function WritePlayers()
	local lines = { string.format("%04d%02d%02d %d",
		Year(), MonthOfYear() + 1, DayOfMonth(), secondsOfDay()) }

	for pn = 1, 2 do
		if GAMESTATE:IsSideJoined(SIDES[pn]) then
			lines[#lines+1] = string.format("p%d %s", pn, ProfileDevice(pn) or "-")
		end
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
		for pn = 1, 2 do
			local s = state[pn]
			s.bpm = (s.geo ~= nil) and ReadHeartRate(s.file) or nil
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

t.ScreenSelectMusic = PublishOnly()
t.ScreenEvaluation = PublishOnly()
t.ScreenEvaluationStage = PublishOnly()
t.ScreenEvaluationNonstop = PublishOnly()
t.ScreenEvaluationSummary = PublishOnly()

return t
