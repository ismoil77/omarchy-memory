# Memory for the Omarchy bar

[Русский](README.ru.md)

RAM in the [Omarchy](https://omarchy.org) bar, and a popup that tells **calm** from **danger** the
way systemd-oomd does — not by "90% used", which is normal on Linux, but by programs waiting for
memory and swap running out.

![The popup](preview.png)

Bar: `󰍛 3.0G` — free memory by default. It turns the theme's yellow when memory is tight and red when
oomd may soon stop an app. Left click opens the popup, right click cycles the label (free → used →
percent → icon only), middle click opens btop.

## What the popup shows

- **verdict**: calm / tight / danger, and why (programs wait for memory, swap is nearly full, almost
  no free memory)
- **the last 10 minutes**: memory used, and pressure as a share of oomd's kill line
- **what RAM is made of**: programs, cache, zram, free
- **pressure** and **swap** against systemd-oomd's own kill lines (read from `oomctl`), with swap
  traffic per second
- **zram**: how much it squeezed, e.g. 7.1 GB into 2.2 GB (3.2×)
- **cache**, with **Free it now**: asks the kernel to drop cached files only (`memory.reclaim` with
  `swappiness=0` on your own app.slice — nothing goes to swap, nothing is killed, no root)
- **apps** holding the most memory, with their icon, the memory each keeps **in swap**, and
  **↑ growing** when one grows by 30 MB a minute. Rows keep their places while the pointer is over
  the list.
  - **open an app** to see what is inside it: browser tabs, extensions, GPU process; for node, php,
    python and the like one line per script and project folder
  - **stop** an app or one line inside it: hover, **Stop**, confirm. If it is still running ~3 s
    later the row offers **Force** (SIGKILL). The kernel decides what may be stopped:
    `Not allowed · system (root)`.
- one warning notification when memory nears oomd's line (two readings in a row; at most every
  10 minutes, whatever the number of monitors)

Keys: `Esc` close · `Enter`/`b` btop · `m` bar label · `r` refresh · `+`/`-` more/fewer apps · `Tab` next panel.

## Light on the system

While the popup is closed the widget starts **no process**: it re-reads `/proc/meminfo` and the
pressure file in place every 3 seconds, and the popup itself is not built until it first opens. `oomctl` runs once at start. While the popup is open,
`apps.py` reads `/proc` every 3 seconds (a few tens of milliseconds), and an opened app is looked
into every 9 seconds.

## Install

```sh
omarchy plugin add https://github.com/ismoil77/omarchy-memory --enable
```

Update with `omarchy plugin update ismoil.memory`. Remove: `omarchy plugin remove ismoil.memory`,
then delete its entry from `shell.json` if it is still there.

## Settings

On the widget entry in `~/.config/omarchy/shell.json`, or in the shell's bar settings:

| Setting | Default | |
|---|---|---|
| `display` | `free` | bar label: `free`, `used`, `percent`, `icon` |
| `notify` | `true` | warn when memory nears oomd's line |
| `language` | `auto` | `en`, `ru`, or the system locale |
| `textSize` | `Normal` | `Normal`, `Large`, `Extra large` |
| `animations` | `true` | |
| `topProcesses` | `10` | apps listed, 1–20 |
| `interval` | `3` | seconds between reads, at least 2 |

`cautionPercent` and `warnPercent` from 1.x are no longer used: the colours follow the verdict.

## Requirements

`python3` (stdlib only) for the app list, `ps`/`awk`/`sort` for stopping and opening an app, `btop`
for the button. systemd-oomd is optional: without it the widget uses its own lines (pressure 60%,
swap 90%). Nothing is sent over the network. Processes are signalled only when you click **Stop**
or **Force**, with your own permissions.

## Tests

```sh
tests/run.sh
```

Python tests for `apps.py` against a fake `/proc`; Node tests for `Model.js` (kernel files, the
verdict, oomd lines, app icons, stable order, texts in both languages), `kit/Contrast.js` against
every stock theme, `kill-group.sh` and `breakdown.sh` against real processes; the libraries in Qt's
engine with `qmltestrunner`; then `omarchy plugin validate`.

## License

MIT

`kit/` is a copy of the shared [omarchy-widget-kit](https://github.com/ismoil77/omarchy-widget-kit); it is edited there, not here.
