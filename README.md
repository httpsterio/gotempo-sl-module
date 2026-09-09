# gotempo — Simply Love heart rate module

Shows your heart rate during gameplay in ITGmania: a heart that beats at your BPM and a
three-digit readout. With one player it sits in the top corner of the header; with two it
splits into a panel per player along the bottom edge, either side of the game-mode text.

## Install

Copy `gotempo.lua` and `heart (mipmaps).png` into Simply Love's `Modules/` folder, then restart.

- Linux — `~/.itgmania/Themes/Simply Love/Modules/`
- Windows — `%APPDATA%\ITGmania\Themes\Simply Love\Modules\`
- macOS — `~/Library/Application Support/ITGmania/Themes/Simply Love/Modules/`

Keep the parentheses in `heart (mipmaps).png`; it's a StepMania filename hint for mipmapping.
With one side joined the panel sits in the header corner opposite your score. With both
joined the header corners are taken by the two scores, so the panels move to the bottom
centre instead: that strip is the one part of a two-player screen that keeps its shape
whatever modifiers are on.

## Data

The module reads `hr.txt` from its own folder once a second and never writes it. One line:

```
154 20260904 52327
```

BPM, date, and seconds since midnight, in local time. Write every second even when the BPM
hasn't changed, or the panel hides after 60 seconds.

With both sides joined it also reads `hr-p2.txt` for P2, in the same format. There is no
`hr-p1.txt`: P1 always reads `hr.txt`, so an existing single-player setup keeps working
untouched. A lone player reads `hr.txt` whichever side they are on.

[gotempo](https://github.com/httpsterio/gotempo) does this from a Bluetooth strap:

```
gotempo --itgmania-module "~/.itgmania/Themes/Simply Love/Modules/gotempo.lua"
```

## Profiles

A player can name their own heart-rate strap in their profile, and gotempo will follow it while
they play. Add `gotempo.ini` to the profile folder:

```ini
[gotempo]
Device=24:AC:AC:18:41:CC
```

The module publishes `players.txt` beside `hr.txt` once a second, on song select, gameplay and
evaluation, saying which sides are joined and what each named. Song select matters: a strap takes
a few seconds to connect, so gotempo has to know before the first note.

Sides that name nothing still appear, as `-`. gotempo needs the difference between "nobody is on
P2" and "someone is on P2 who named nothing", since the first leaves that slot alone and the
second puts the machine's configured strap on it.

## Config

Top of `gotempo.lua`.

Positions are in the theme's own units, not display pixels: Simply Love designs against a
480-tall screen with the width following the aspect ratio, so 16:9 is about 854x480.

The two-player panels size themselves to the space between the game-mode text and each
playfield, asking the theme where that playfield actually is (`GetNotefieldX`,
`GetNotefieldWidth`) rather than assuming. The fields are not necessarily symmetric about
the centre, since `NoteFieldOffsetX` is a per-player modifier. At 16:9 with dance/versus
this leaves about 46 units per panel, against the 170 the single-player header panel gets.

In that slot the panel stacks a centred heart above the digits rather than setting them side
by side, which is what keeps the digits legible: sharing a row with the icon caps them near
zoom 0.15, a row of their own reaches about 0.29. Both rows being centred also makes the two
panels symmetric without either needing to be mirrored.

The stack is built upward from `DUAL_DIGIT_BOTTOM` rather than centred in the panel: the
digits sit beside the game-mode text and should agree with its line, so they hold a fixed
position and the heart grows away from them. Enlarging the heart therefore needs
`DUAL_HEIGHT` raised to match, or it clips out of the panel top.

| | Default | |
| --- | --- | --- |
| `HR_FILES` | `Modules/hr.txt`, `Modules/hr-p2.txt` | Files to read, P1 and P2 |
| `POLL_SECONDS` | `1` | Read interval |
| `DEBUG_BG` | `false` | Paint each panel a bright colour and keep it visible with no reading, to see the space it occupies while positioning. Turn off when done |
| `DEBUG_BG_COLORS` | magenta, cyan | Debug colour per player |
| `CORNER_SIDE` | `"auto"` | One player only: `auto`, `left` or `right` |
| `DUAL_INSET` | `0.042` | Two players: gap from centre, as a fraction of width, clearing the game-mode text |
| `DUAL_OUTSET` | `0.10` | Two players: fallback outer reach, used only when the theme cannot report where the playfield starts |
| `DUAL_FIELD_GAP` | `4` | Two players: clearance between a panel and the playfield beside it |
| `DUAL_MIN_WIDTH` | `40` | Two players: floor on panel width |
| `DUAL_PADDING` | `2` | Two players: inset inside the panel |
| `DUAL_TEXT_SCALE` | `1` | Two players: digit size, as a fraction of "three digits fill the width" |
| `DUAL_ICON_SCALE` | `2.4` | Two players: heart height relative to the digits |
| `DUAL_STACK_GAP` | `9.5` | Two players: gap between the heart and the digits |
| `DUAL_DIGIT_BOTTOM` | `23` | Two players: panel bottom to the digits' centre line. Raise to move the digits up |
| `DUAL_HEIGHT` | `64` | Two players: panel height. Must fit the digits' line plus the heart above it |
| `DUAL_MARGIN_BOTTOM` | `6` | Two players: gap to the bottom edge |
| `PANEL_Y` | `15` | One player: top edge |
| `PANEL_HEIGHT` | `50` | One player: panel height |
| `PANEL_WIDTH` | `170` | One player: panel width |
| `PANEL_MARGIN` | `10` | One player: gap to the screen edge |
| `PADDING` | `5` | Inset inside the panel |
| `TEXT_SCALE` | `0.84` | Digit size |
| `INK_OFFSET` | `22` | Digits up |
| `ICON_TEXTURE` | `heart (mipmaps).png` | |
| `ICON_SCALE` | `1.6` | Heart size |
| `ICON_GAP` | `6` | Gap to the digits |
| `ICON_Y_NUDGE` | `-5` | Heart up |
| `PULSE` | `true` | Beat at the current BPM |
| `PULSE_MAGNITUDE` | `1.15` | Swell per beat |
| `BG_COLOR` | transparent | |
| `TEXT_COLOR` | `#ffffff` | |
| `STALE_COLOR` | `#555555` | |
| `STALE_TEXT` | `"..."` | Shown with no reading |
| `STALE_ALPHA` | `0.35` | Heart dim with no reading |
| `MIN_BPM` / `MAX_BPM` | `20` / `999` | Outside this hides the panel |
| `STALE_AFTER_SECONDS` | `60` | Timestamp age before hiding |
| `HIDE_WHEN_STALE` | `true` | `false` shows `STALE_TEXT` instead |
