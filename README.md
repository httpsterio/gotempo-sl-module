# gotempo — Simply Love heart rate module

Shows your heart rate during gameplay in ITGmania, and draws it over the density graph on the
evaluation screen afterwards: a heart that beats at your BPM and a
three-digit readout. With one player it sits in the top corner of the header; with two it
splits into a panel per player along the bottom edge, either side of the game-mode text.

## Install

Copy `gotempo.lua` and the `gotempo/` folder into Simply Love's `Modules/` folder, then restart.
The `.lua` has to sit directly in `Modules/`: the loader lists that folder without recursing and
keeps only `*.lua`. Everything else this module owns lives in `Modules/gotempo/`.

- Linux — `~/.itgmania/Themes/Simply Love/Modules/`
- Windows — `%APPDATA%\ITGmania\Themes\Simply Love\Modules\`
- macOS — `~/Library/Application Support/ITGmania/Themes/Simply Love/Modules/`

Keep the parentheses in `gotempo/heart (mipmaps).png`; it's a StepMania filename hint for mipmapping.
With one side joined the panel sits in the header corner opposite your score. With both
joined the header corners are taken by the two scores, so the panels move to the bottom
centre instead: that strip is the one part of a two-player screen that keeps its shape
whatever modifiers are on.

## Data

The module reads `gotempo/hr.txt` once a second and never writes it. One line:

```
154 20260904 52327
```

BPM, date, and seconds since midnight, in local time. Write every second even when the BPM
hasn't changed, or the panel hides after 60 seconds.

P2 reads `gotempo/hr-p2.txt`, same format. There is no `hr-p1.txt`, so an existing single-player setup
keeps working untouched.

It writes one file, `gotempo/players.txt`, which is how gotempo knows who is playing and therefore which
strap to connect for each side. Rewritten once a second on song select, gameplay and evaluation:

```
20260908 52327
p1 24:AC:AC:18:41:CC
p2 -
```

Date and seconds since midnight, then a line per joined side naming that player's strap, or `-`
if they have none. A side with nobody on it gets no line. gotempo releases the straps when the
stamp stops advancing, which is what covers the game being closed or killed.

[gotempo](https://github.com/httpsterio/gotempo) does this from a Bluetooth strap:

```
gotempo --itgmania-module "~/.itgmania/Themes/Simply Love/Modules/gotempo.lua"
```

## Profiles

A player can name their own strap in their profile and gotempo follows it while they play. Add
`gotempo.ini` to the profile folder:

```ini
[gotempo]
Device=24:AC:AC:18:41:CC
Color=#FF4FA3
Thickness=1.4
```

Pair the strap to the machine once first. Nothing is saved on gotempo's side, so leaving the song
flow, or quitting the game, hands the straps back to whatever it was set to before.

You do not have to write any of this by hand. In game, open the sort menu on the song wheel
(**Select+Start** by default) and go to **Advanced → gotempo**. Each joined player gets their
own panel, driven by their own controller, showing their current strap and its live reading:

```
┌──────────────────────────────┐  ┌──────────────────────────────┐
│  P1 · http                   │  │  P2 · Sami KB · unsaved      │
│  ✓ Polar H10 1841CC31        │  │  ✗ No strap selected         │
│    72 bpm                    │  │                              │
│  ──────────────────────────  │  │  ──────────────────────────  │
│  ▸ Change strap              │  │  ▸ Choose a strap            │
│    Remove strap              │  │    Line colour    ◂ FF4FA3 ▸ │
│    Line colour    ◂ F56C27 ▸ │  │    Line thickness ◂ 1.0 ▸    │
│    Line thickness ◂ 1.4 ▸    │  │    Save and exit             │
│    Save and exit             │  │    Back without saving       │
│    Exit                      │  │                              │
└──────────────────────────────┘  └──────────────────────────────┘
```

Up and down move, left and right change a value, **Start** selects. Nothing is written until
**Save and exit**, so a pick can be undone by leaving. **Back** steps out of the strap list,
and at the top level it parks the cursor on Save rather than acting, so the reflex press
lands on the safe outcome.

The menu closes when every joined player is done, not when the first one is — so P1 finishing
does not take the screen away from P2. One player can drive both panels using the other side's
buttons, as at any cabinet. A side with no profile loaded can save nothing and never holds the
menu open.

Choosing a strap scans for what is in range; gotempo does the scanning, since this module has
no Bluetooth of its own, so gotempo has to be running. Whoever asks first starts the scan and
both panels fill at once. Straps nobody has claimed are listed first, then a divider, then
ones some profile already names with the names beside them — which is what makes the list
readable in a room with several cabinets. Those are still pickable: two players sharing one
strap is allowed, and gotempo connects it once and feeds both sides.

`Color` and `Thickness` are optional and affect only that player's evaluation graph: the line, its
labels and the mean rule. `Color` is hex, with or without the `#`, six digits or eight for an
alpha. `Thickness` multiplies the configured width, capped at 4, and holds at every slope rather
than only on the flat. Anything missing, empty or malformed falls back to the values in
`gotempo.lua`, so a typo costs you the setting and not the graph.

## Evaluation graph

After a song, your heart rate is drawn as a pink line over the density graph, sharing its time
axis so a peak sits above the part of the chart that caused it. Two players each get their own.

Press **MenuDown** at the evaluation screen to fold the line away and again to bring it back, per
side, for as long as the game is running. The line is drawn over the density graph, so this is
there for reading the timing dots underneath. MenuUp is deliberately not used: on a pad it is part
of Simply Love's favourite-song code.

Samples are kept in memory for one song and thrown away when the next starts; nothing is written
and nothing accumulates. They are bucketed into `HR_GRAPH_POINTS` evenly spaced points and run
through a short moving average, so the line shows effort rather than sensor jitter. Course modes
are skipped: their density graph is built from several songs and one song's samples would not line
up with it.

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
| `HR_FILES` | `Modules/gotempo/hr.txt`, `hr-p2.txt` | Files to read, P1 and P2 |
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
| `ICON_TEXTURE` | `gotempo/heart (mipmaps).png` | |
| `ICON_SCALE` | `1.6` | Heart size |
| `ICON_GAP` | `6` | Gap to the digits |
| `ICON_Y_NUDGE` | `-5` | Heart up |
| `PULSE` | `true` | Beat at the current BPM |
| `HR_GRAPH` | `true` | Draw the line on the evaluation screen |
| `HR_GRAPH_POINTS` | `48` | Points across the graph; raise for detail |
| `HR_GRAPH_SMOOTH` | `3` | Moving-average window in points; `1` disables |
| `HR_GRAPH_MIN` / `HR_GRAPH_MAX` | `40` / `200` | BPM at the bottom and top of the box |
| `HR_GRAPH_THICKNESS` | `1.5` | Half-height of the line |
| `HR_GRAPH_COLOR` | pink | |
| `PULSE_MAGNITUDE` | `1.15` | Swell per beat |
| `BG_COLOR` | transparent | |
| `TEXT_COLOR` | `#ffffff` | |
| `STALE_COLOR` | `#555555` | |
| `STALE_TEXT` | `"..."` | Shown with no reading |
| `STALE_ALPHA` | `0.35` | Heart dim with no reading |
| `MIN_BPM` / `MAX_BPM` | `20` / `999` | Outside this hides the panel |
| `STALE_AFTER_SECONDS` | `60` | Timestamp age before hiding |
| `HIDE_WHEN_STALE` | `true` | `false` shows `STALE_TEXT` instead |

## Tests

The parts that are pure logic -- reading gotempo's device list, ordering the picker, the
profile ini round-trip -- run outside the game:

```
python3 mkharness.py && lua5.1 picker_test.lua
```

It exits non-zero on failure. Check that rather than grepping the output for `FAIL`: a
script that errors part-way prints no failures at all and reads as a pass.

`mkharness.py` lifts the real function bodies out of `gotempo.lua` rather than copying
them, so the tests cannot drift from the source. It also fails on two top-level functions
sharing a name: the later one silently shadows the earlier for everything below it, which
is legal Lua and invisible to `luac`.

Use `luac5.1 -p gotempo.lua` to syntax check. The engine is Lua 5.1, and a newer `luac`
accepts syntax it rejects — `\u{...}` escapes in particular.

Text is drawn in `Common Normal`, which redirects to the bitmap font `Miso/_miso light`.
Its pages cover CP1252 plus Latin-2 and Cyrillic, so `… — · × « » • ‹ ›` are available and
anything outside that (`✓ ✗ ● ▸`, geometric shapes, dingbats) draws as a missing-glyph box.
Check a new symbol against `Fonts/Miso/_miso light.ini` before using it.
