# Changelog

## 2.1.0 — family look and audit

- The family look (kit 2): one header, sections, buttons and signature across ismoil widgets.
- The popup is built the first time it opens, not at shell start on every monitor; the list of
  installed apps (names, icons) is built with it and each row is matched once, not at every reading.
- One warning for the whole desktop (two monitors used to send two), at most every 10 minutes; extra
  readings (opening, a key, IPC) no longer count toward it or add points to the 10-minute chart.
- Stopping an inner line goes through `kill-group.sh`, which looks the app's processes up again:
  a PID reused since the list was read is never signalled.
- An opened app that exits closes its row (the list was frozen and `breakdown.sh` kept running).
- `+` / `-` walk the presets from any count (12 → 15 / 10). `breakdown.sh` prints with `printf`.
- Removed unused texts and helpers.

## 2.0.0 — calm or danger, the way oomd sees it

- New look (kit 1.2): verdict chip, a 10-minute chart, what RAM is made of, tiles for pressure,
  swap, zram and cache, apps in a card with their icons.
- The verdict follows systemd-oomd: pressure and swap against its kill lines from `oomctl`, not
  "% used". `cautionPercent` / `warnPercent` are gone.
- zram ratio, swap traffic per second, memory each app keeps in swap, "↑ growing".
- **Free it now**: drops cached files through your app.slice's `memory.reclaim` (`swappiness=0`, no root).
- Open an app to see what is inside it (tabs, extensions, scripts per project) and stop one line.
- Rows keep their places under the pointer.
- A notification when memory nears oomd's line (`notify`).
- English and Russian (`language`), `textSize`, `animations`.
- Lighter: no process while the popup is closed (kernel files re-read in place); `apps.py` replaces
  a five-process `ps` pipeline and runs every 3 s instead of 1.5 s, only while open.

## 1.3.1 — safer Stop

- `kill-group.sh`: an empty name or a signal other than TERM/KILL signals nothing and exits 2; the
  name is matched literally (no backslash or regex expansion).
- The row says "Unable to stop" when the script gives no answer or "Stopping…" lasts over 5 s, and
  "Not running" when nothing by that name was left, instead of silently clearing.
- The script path is URL-decoded, so a plugins folder with spaces works.
- Manifest: `topProcesses` accepts 1–20. README: licence heading.

## 1.3.0 — theme colours

- Colours follow the theme: accent while memory is fine, yellow from `cautionPercent` (default 75),
  red from `warnPercent` (default 90). The bar label changes colour at the same levels.
- The popup uses the theme's popup text and background, with colours held to WCAG contrast.
- Usage thresholds live in `Model.level()`; tests for the library, `Contrast.js` and `kill-group.sh`.

## 1.2.0

- Stop a program from the process list (SIGTERM, then Force), with the kernel's refusals reported.
