# gotempo — Simply Love heart rate module

Shows your heart rate during gameplay in ITGmania, and draws it over the density graph on the
evaluation screen afterwards: a heart that beats at your BPM and a three-digit readout. With one
player it sits in the top corner of the header; with two it splits into a panel per player along
the bottom edge, either side of the game-mode text.

The Bluetooth half is [gotempo](https://github.com/httpsterio/gotempo/), a tray app that connects
to the strap and writes the readings to a file. This module only reads that file. You need both.

## Setup

1. Pair the strap to the machine, outside ITGmania.
   - Linux: `bluetoothctl`, then `pair` and `trust`
   - Windows: Settings → Bluetooth & devices
2. Download [gotempo](https://github.com/httpsterio/gotempo/releases/latest) and run it. It writes a default config. Quit it from the tray.
3. Download the [module zip](https://github.com/httpsterio/gotempo-sl-module/releases/latest) and copy
   `gotempo.lua` and the `gotempo/` folder out of it into the `Modules/` folder of the theme you play.
   - Linux: `~/.itgmania/Themes/Simply Love/Modules/`
   - Windows: `%APPDATA%\ITGmania\Themes\Simply Love\Modules\`
   - macOS: `~/Library/Application Support/ITGmania/Themes/Simply Love/Modules/`

   `gotempo.lua` goes directly in `Modules/`, not in a subfolder. Do not rename `gotempo/heart (mipmaps).png`.
4. Open the config and set `itgmania_module` to the full path of the copy you just made.
   - Linux: `~/.config/gotempo/config.json`
   - Windows: `%LOCALAPPDATA%\gotempo\config.json`

```json
   "itgmania_module": "/home/you/.itgmania/Themes/Simply Love/Modules/gotempo.lua"
```
5. Start gotempo, then start ITGmania.
6. On the song wheel press Left+Right to open the Sort Menu. Go to Advanced → gotempo.
7. Put on your HR strap.
7. Select "Choose a strap" and wait for the scan to finish.
8. Select your strap, save and exit
9. Wait for a few seconds and the heart icon in the top row should go bright red. You're now ready!

Steps 2 and 4 in one command:

```
gotempo --itgmania-module "~/.itgmania/Themes/Simply Love/Modules/gotempo.lua"
```

Quit from the tray afterwards, then carry on from step 3.

## Data

The module reads `gotempo/hr.txt` once a second and never writes it. One line:

```
154 20260904 52327
```

BPM, date, and seconds since midnight, in local time. Write on every reading even when the BPM
hasn't changed: the timestamp is how the module knows readings are still arriving, and once it
stops moving for three seconds the panel hides and the song wheel heart dims.

P2 reads `gotempo/hr-p2.txt`, same format. There is no `hr-p1.txt`, so an existing single-player setup
keeps working untouched.

It writes `gotempo/players.txt`, which is how gotempo knows who is playing and therefore which
strap to connect for each side. Rewritten once a second on the song wheel, and every three seconds
during a song and on the results screen:

```
20260908 52327
p1 24:AC:AC:18:41:CC
p2 -
```

Date and seconds since midnight, then a line per joined side naming that player's strap, or `-`
if they have none. A side with nobody on it gets no line. gotempo releases the straps when the
stamp stops advancing, which is what covers the game being closed or killed.

Each player's `gotempo.ini` is read once per profile rather than every second: again when a
different profile is loaded, including with Switch Profile on the song wheel, after the picker
saves, and on each visit to the song wheel so a hand edit is picked up. During a song and on the
results screen the player lines are taken once when the screen opens, so the only file a song
reads is `hr.txt`.

The strap picker adds a fourth line, `scan <token>`, while it is open. gotempo answers by scanning
and writing `gotempo/devices.txt`, which the picker reads and which gotempo blanks again about a
minute later. This module has no Bluetooth of its own, so asking is the only way it can find out
what is in range.

gotempo first writes `devices.txt` with only its stamp and the word `scanning`, before the scan
starts, then the list about fifteen seconds later. No acknowledgement within a few seconds means
gotempo is not running; an acknowledged scan that never finishes is reported separately. This
needs gotempo 2.0.1 or later; with 2.0.0 the picker reports gotempo not running.

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
│  http                        │  │  Sami KB (unsaved)           │
│  ✓ Polar H10 1841CC31        │  │  ✗ No strap selected         │
│    72 bpm                    │  │                              │
│  ──────────────────────────  │  │  ──────────────────────────  │
│  › Change strap              │  │  › Choose a strap            │
│    Remove strap              │  │    Line colour  ■ ‹ red ›    │
│    Line colour ■ ‹ coral ›   │  │    Line thickness ‹ 1.0 ›    │
│    Line thickness ‹ 1.4 ›    │  │    Save and exit             │
│    Save and exit             │  │    Back without saving       │
│    Exit                      │  │                              │
└──────────────────────────────┘  └──────────────────────────────┘
```

Up and down move, left and right change a value (hold to keep stepping; both lists wrap),
**Start** selects. Nothing is written until **Save and exit**, and then only the settings you
actually changed, so a pick can be undone by leaving and a colour or thickness you set by hand
survives a visit to change strap. **Back** steps out of the strap list,
and at the top level it parks the cursor on Save rather than acting, so the reflex press
lands on the safe outcome.

The menu closes when every joined player is done, not when the first one is — so P1 finishing
does not take the screen away from P2. One player can drive both panels using the other side's
buttons, as at any cabinet. A side with no profile loaded can save nothing and never holds the
menu open.

Choosing a strap scans for what is in range; gotempo does the scanning, since this module has
no Bluetooth of its own, so gotempo has to be running. Whoever asks first starts the scan and
both panels fill at once. The player's own strap is listed first in green, then straps nobody
has claimed, then ones some profile already names, with the profile beside the MAC. A profile
joined right now also shows its side, as `P3 (P2)`. That is what makes the list readable in a
room with several cabinets. Claimed straps are still pickable: two players sharing one strap is
allowed, and gotempo connects it once and feeds both sides.

`Color` and `Thickness` are optional and affect only that player's evaluation graph: the line, its
labels and the mean rule. Without them the line is red.

`Color` is hex, with or without the `#`, six digits or eight for an alpha. The menu offers a named
palette, and a colour set by hand that isn't in it is added to the list as **P1 custom** or
**P2 custom** while that player is joined — offered to the other player too, and gone from the
list once nobody has it saved.

`Thickness` multiplies the configured width and holds at every slope rather than only on the
flat. It runs from 0.1 to 4.0 in tenths: a finer value such as `1.25` is drawn as `1.3`, and
values outside the range are pulled back into it. The file keeps what you wrote until you change
thickness in the menu. Zero, negative or non-numeric values fall back to the default, so a typo
costs you the setting and not the graph.

## Evaluation graph

After a song, your heart rate is drawn as a line over the density graph, sharing its time
axis so a peak sits above the part of the chart that caused it. Two players each get their own.

Press **MenuDown** at the evaluation screen to fold the line away and again to bring it back, per
side, for as long as the game is running. The line is drawn over the density graph, so this is
there for reading the timing dots underneath. MenuUp is deliberately not used: on a pad it is part
of Simply Love's favourite-song code.

Samples are kept in memory for one song and thrown away when the next starts; nothing is written
and nothing accumulates. They are grouped into `HR_GRAPH_POINTS` buckets by position along the
song and plotted at each bucket's mean sample time, so the line reaches both ends of the box
instead of being inset by half a bucket, then run through a short moving average so it shows
effort rather than sensor jitter.

The scale comes from the readings themselves rather than a fixed range, with `HR_GRAPH_PAD`
headroom so the peak does not sit on the edge. That is why the min, mean and max labels matter:
they are what say whether the line was a warmup or a wall.

Course modes are skipped: their density graph is built from several songs and one song's samples
would not line up with it.

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
| `PUBLISH_IN_SONG_SECONDS` | `3` | How often `players.txt` is restamped in a song and on the results screen. Must stay well under gotempo's 10-second timeout |
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
| `HR_GRAPH_POINTS` | `64` | Points across the graph; raise for detail |
| `HR_GRAPH_SMOOTH` | `1` | Moving-average window in points; `1` disables |
| `HR_GRAPH_PAD` | `0.1` | Headroom above and below the range, as a fraction of it |
| `HR_GRAPH_GAP` | `3` | Seconds of silence that break the line rather than bridging it |
| `HR_GRAPH_THICKNESS` | `1.5` | Half-width of the line, measured across it. A profile's `Thickness` multiplies this |
| `HR_DEFAULT_COLOR` | `"#FF5555"` | The line's colour with no `Color` set. Looked up by hex, so reordering the palette cannot change it |
| `HR_GRAPH_COLOR` | red | Built from `HR_DEFAULT_COLOR`; overridden per player by `Color` |
| `HR_GRAPH_TOGGLE` | `"MenuDown"` | Folds the line away at the evaluation screen |
| `HR_STALE_SECONDS` | `3` | Seconds without a new timestamp before a reading counts as stale: the header heart dims, the gameplay panel hides and the graph stops collecting |
| `HR_LABEL_ZOOM` | `0.13` | Min/mean/max label size |
| `HR_LABEL_INSET` | `1` | Labels in from the box's left edge |
| `HR_LABEL_PAD` | `2` | Inset around the label text, inside its backing |
| `HR_LABEL_COLOR` | red | Same as the line; overridden per player by `Color` |
| `HR_LABEL_BG` | black, 0.65 | Backing, since the density bars run underneath |
| `HR_MEAN_LINE` | red, half alpha | Rule across the box at the mean, in the line's colour |
| `HR_MEAN_LINE_H` | `0.7` | Its thickness |
| `EVAL_PANE_W` / `EVAL_PANE_GAP` | `300` / `10` | Simply Love's pane geometry, recomputed here because a module cannot reach into the screen |
| `EVAL_GRAPH_Y` | `124` | Graph box, below screen centre |
| `EVAL_ONE_PLAYER_NUDGE` | `0.2541` | One player: the density graph's offset within its pane |
| `HR_COLOR_CHOICES` | 18 named colours | What the picker's **Line colour** row steps through; names shown, hex stored |
| `HR_THICKNESS_CHOICES` | `0.1` … `4.0` | What **Line thickness** steps through, in tenths |
| `HR_THICKNESS_MIN` / `HR_THICKNESS_MAX` | `0.1` / `4` | Range a `Thickness` is rounded and clamped into |
| `STATUS_HEART` | `true` | Heart in the song wheel's header, one per side |
| `STATUS_HEART_SIZE` | `14` | |
| `STATUS_HEART_X` | `130` | Either side of screen centre, flanking the header's clock |
| `STATUS_HEART_Y` | `16` | Centre of the 32-unit header bar |
| `STATUS_HEART_LIVE` / `STATUS_HEART_DEAD` | pink / faint white | Reading arriving, or not |
| `SORTMENU_TOP` / `SORTMENU_BOTTOM` | `"HR Strap Config"` / `"gotempo"` | The sort menu row. The bottom line is also the key the theme dispatches on |
| `SCAN_ACK_WAIT` | `6` | Seconds to wait for gotempo to acknowledge a scan request before reporting it not running |
| `SCAN_WAIT` | `45` | Seconds an acknowledged scan may take before the picker reports it did not finish |
| `DEVICES_MAX_AGE` | `60` | Seconds before a published strap list is ignored; matches gotempo, which blanks it at the same age |
| `PULSE_MAGNITUDE` | `1.15` | Swell per beat |
| `BG_COLOR` | transparent | |
| `TEXT_COLOR` | `#ffffff` | |
| `STALE_COLOR` | `#555555` | |
| `STALE_TEXT` | `"..."` | Shown with no reading |
| `STALE_ALPHA` | `0.35` | Heart dim with no reading |
| `MIN_BPM` / `MAX_BPM` | `20` / `999` | Outside this hides the panel |
| `STALE_AFTER_SECONDS` | `60` | Outer limit on a timestamp's age, for a file read once with nothing to compare against. `HR_STALE_SECONDS` is what normally hides a reading |
| `HIDE_WHEN_STALE` | `true` | `false` shows `STALE_TEXT` instead |

## Tests

The parts that are pure logic -- reading gotempo's device list, ordering the picker, the
profile ini round-trip -- run outside the game:

```
python3 mkharness.py && lua5.1 picker_test.lua
```

It exits non-zero on failure. Check that rather than grepping the output for `FAIL`: a
script that errors part-way prints no failures at all and reads as a pass.

`make check` runs the syntax check and the tests together. `make dist VERSION=v2.0.0` builds the
release zip into `dist/` with only the files a player installs. `make release VERSION=v2.0.0` tags
and pushes, and the tag triggers CI to build the same zip and publish it.

`mkharness.py` lifts the real function bodies out of `gotempo.lua` rather than copying
them, so the tests cannot drift from the source. It also fails on two top-level functions
sharing a name: the later one silently shadows the earlier for everything below it, which
is legal Lua and invisible to `luac`.

Use `luac5.1 -p gotempo.lua` to syntax check. The engine is Lua 5.1, and a newer `luac`
accepts syntax it rejects — `\u{...}` escapes in particular.

Text is drawn in `Common Normal`, which redirects to the bitmap font `Miso/_miso light`.
Its pages cover CP1252 plus Latin-2 and Cyrillic, so `‹ ›` are available and anything outside
that (`✓ ✗ ● ▸`, geometric shapes, dingbats) draws as a missing-glyph box. The status check and
cross are drawn with quads for that reason. Check a new symbol against
`Fonts/Miso/_miso light.ini` before using it.
