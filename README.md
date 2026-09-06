# gotempo — Simply Love heart rate module

Shows your heart rate during gameplay in ITGmania: a heart that beats at your BPM and a
three-digit readout in the top corner of the header.

## Install

Copy `gotempo.lua` and `heart (mipmaps).png` into Simply Love's `Modules/` folder, then restart.

- Linux — `~/.itgmania/Themes/Simply Love/Modules/`
- Windows — `%APPDATA%\ITGmania\Themes\Simply Love\Modules\`
- macOS — `~/Library/Application Support/ITGmania/Themes/Simply Love/Modules/`

Keep the parentheses in `heart (mipmaps).png`; it's a StepMania filename hint for mipmapping.
The panel sits in the header corner opposite your score, and only with one side joined.

## Data

The module reads `hr.txt` from its own folder once a second and never writes it. One line:

```
154 20260904 52327
```

BPM, date, and seconds since midnight, in local time. Write every second even when the BPM
hasn't changed, or the panel hides after 60 seconds.

[gotempo](https://github.com/httpsterio/gotempo) does this from a Bluetooth strap:

```
gotempo --itgmania-module "~/.itgmania/Themes/Simply Love/Modules/gotempo.lua"
```

## Config

Top of `gotempo.lua`.

| | Default | |
| --- | --- | --- |
| `HR_FILE` | `Modules/hr.txt` | File to read |
| `POLL_SECONDS` | `1` | Read interval |
| `CORNER_SIDE` | `"auto"` | `auto`, `left` or `right` |
| `PANEL_Y` | `15` | Top edge |
| `PANEL_HEIGHT` | `50` | |
| `PANEL_WIDTH` | `170` | |
| `PANEL_MARGIN` | `10` | Gap to the screen edge |
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
