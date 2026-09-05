-- Heart rate display for Simply Love
--
-- Reads a BPM value from Modules/hr.txt and draws it into a free corner of
-- ScreenGameplay's header bar.
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
-- The panel lives in the ScreenGameplay header -- the 80px black bar across the
-- top, drawn by Shared/Header.lua.  Its middle is taken by the song meter (417px
-- wide, centred) and each player's score sits just inside that on their own side,
-- which leaves the far corner opposite a player's score free in every layout:
-- centred or not, and whatever DataVisualizations is set to.  That is the only
-- space on this screen with those properties, so the panel does not need to know
-- anything about the notefield, the modifiers, or what other modules are loaded.

-------------------------------------------
-------( Configuration Parameters )--------
-------------------------------------------

local HR_FILE = THEME:GetCurrentThemeDirectory() .. "Modules/hr.txt"
local POLL_SECONDS = 1

-- The header is 80px tall, so a 50px panel at y=15 sits centred in it.
local PANEL_Y = 15
local PANEL_HEIGHT = 50
local PANEL_WIDTH = 170
local PANEL_MARGIN = 10		-- gap between the panel and the screen edge
local PADDING = 5

-- Which corner to sit in.  "auto" picks the one opposite this player's score
-- display, which is the free one: P1's score sits left of centre, P2's right of
-- it.  Force it with "left" or "right" if something in your setup claims that
-- corner -- the NPSGraphAtTop modifier is the one that does, since it pushes the
-- BPM readout out of the centre and into exactly this space.
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

-- Transparent by default: the header is already a dark bar, and a second black
-- quad on top of it shows up as a visibly darker rectangle.  Give this an alpha
-- if you move the panel somewhere that has no backdrop of its own.
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

local bpm = nil
local pulseBpm = nil
local active = false	-- are we in a layout that reserved a slot for us?


local function secondsOfDay()
	return Hour()*3600 + Minute()*60 + Second()
end


-- YYYYMMDD as an integer.  MonthOfYear() is 0-based, hence the +1.
local function todayStamp()
	return Year()*10000 + (MonthOfYear()+1)*100 + DayOfMonth()
end


local function ReadHeartRate()
	local file = RageFileUtil.CreateRageFile()
	local text = nil

	if file:Open(HR_FILE, 1) then
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


-- Returns the x of the panel's left edge and its width, or nil when there is no
-- corner to use.
local function PanelGeometry()
	local p1 = GAMESTATE:IsSideJoined("PlayerNumber_P1")
	local p2 = GAMESTATE:IsSideJoined("PlayerNumber_P2")

	-- With both sides joined the two scores claim a corner each and neither is
	-- free.  There is only ever one heart rate in the file anyway, so there would
	-- be no honest way to label it.
	if p1 == p2 then return nil end

	local side = CORNER_SIDE
	if side == "auto" then side = p1 and "right" or "left" end

	local x = PANEL_MARGIN
	if side == "right" then x = _screen.w - PANEL_WIDTH - PANEL_MARGIN end

	return x, PANEL_WIDTH
end


-- Everything the children need to lay themselves out, derived from the panel
-- width so the readout scales with the chat box rather than being hardcoded.
local function ContentGeometry(width)
	local slot = (width - PADDING*2) / SLOTS
	local digitZoom = (slot / DIGIT_WIDTH) * TEXT_SCALE
	local iconSize = CAP_HEIGHT * digitZoom * ICON_SCALE

	return {
		width=width,
		digitZoom=digitZoom,
		iconSize=iconSize,
		iconX=PADDING + iconSize/2,		-- the icon is centered, so it can pulse in place
		iconY=PANEL_HEIGHT/2 + ICON_Y_NUDGE,
		digitX=PADDING + iconSize + ICON_GAP,
		digitY=PANEL_HEIGHT/2 - INK_OFFSET*digitZoom,
	}
end


local t = {}

t.ScreenGameplay = Def.ActorFrame{
	ModuleCommand=function(self)
		local x, width = PanelGeometry()

		self:stoptweening()

		active = (x ~= nil)
		if not active then
			self:visible(false)
			return
		end

		bpm = nil
		pulseBpm = nil

		-- Stay hidden until the first Tick has actually read the file, so entering
		-- gameplay never flashes a frame of placeholder text.
		self:visible(false)
		self:xy(x, PANEL_Y)
		self:playcommand("SetGeometry", ContentGeometry(width))
		self:queuecommand("Tick")
	end,

	TickCommand=function(self)
		bpm = ReadHeartRate()
		-- Re-evaluated every poll, not just on screen entry: the sensor can drop
		-- out mid-song, and should bring the panel back on its own when it returns.
		self:visible(active and (bpm ~= nil or not HIDE_WHEN_STALE))
		self:playcommand("Refresh")
		self:sleep(POLL_SECONDS):queuecommand("Tick")
	end,

	Def.Quad{
		InitCommand=function(self)
			self:halign(0):valign(0):diffuse(BG_COLOR)
		end,
		SetGeometryCommand=function(self, params)
			self:zoomto(params.width, PANEL_HEIGHT)
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
			if bpm == nil then
				self:stopeffect()
				pulseBpm = nil
			elseif PULSE and bpm ~= pulseBpm then
				self:pulse():effectmagnitude(1, PULSE_MAGNITUDE, 0):effectperiod(60/bpm)
				pulseBpm = bpm
			end
		end,

		Def.Sprite{
			Name="Icon",
			Texture=ICON_TEXTURE,
			SizeIconCommand=function(self, params)
				self:zoomto(params.iconSize, params.iconSize)
			end,
			RefreshCommand=function(self)
				self:diffusealpha(bpm and 1 or STALE_ALPHA)
			end,
		},
	},

	LoadFont("Wendy/_wendy monospace numbers")..{
		Text=STALE_TEXT,
		InitCommand=function(self)
			self:halign(0):valign(0.5)
		end,
		SetGeometryCommand=function(self, params)
			self:zoom(params.digitZoom)
			self:xy(params.digitX, params.digitY)
		end,
		RefreshCommand=function(self)
			if bpm then
				self:settext(string.format("%03d", bpm)):diffuse(TEXT_COLOR)
			else
				self:settext(STALE_TEXT):diffuse(STALE_COLOR)
			end
		end,
	},
}

return t
