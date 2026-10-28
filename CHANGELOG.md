# Changelog

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
