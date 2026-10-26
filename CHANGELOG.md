# Changelog

## 1.3.0 — theme colours

- Colours follow the theme: accent while memory is fine, yellow from `cautionPercent` (default 75),
  red from `warnPercent` (default 90). The bar label changes colour at the same levels.
- The popup uses the theme's popup text and background, with colours held to WCAG contrast.
- Usage thresholds live in `Model.level()`; tests for the library, `Contrast.js` and `kill-group.sh`.

## 1.2.0

- Stop a program from the process list (SIGTERM, then Force), with the kernel's refusals reported.
