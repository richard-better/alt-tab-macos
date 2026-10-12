# Appearance (window sizing) — Specs

> **Line coverage:** `AppearanceTestable.swift` 79% · _refreshed 2026-05-27 by `/coverage-explore`_

## Summary

Two pure sizing functions in `AppearanceTestable` decide how big the switcher's thumbnails are on a
given display, so the UI feels right from an 11" laptop to a 60" TV. The suite pins their output against
a table of **21 real device models** (laptops, monitors, ultrawides, TVs) with known pixel + physical
dimensions, so a tweak to the formula can't silently regress any class of screen.

- `comfortableWidth(physicalDimension)` → the fraction of the screen the switcher should occupy (smaller
  fraction on bigger/wider screens, separate expectations for horizontal vs vertical use).
- `goodValuesForThumbnailsWidthMinMax(ratio, rowCount)` → the (min, max) thumbnail width for a given
  screen aspect ratio and row count (3, 4, or 5 rows).

## Behavior & edge cases

- Driven entirely by a fixture table: each row is `(model, pixels, physical-mm, expected comfortable
  fractions, [(rowCount, expectedMin, expectedMax)])`. Both tests loop the table and assert with `0.01`
  tolerance, naming the failing model.
- Bigger physical screens get a smaller comfortable fraction (a 60" TV shouldn't show a half-screen
  switcher); ultrawides get distinct horizontal vs vertical fractions.

## Test scenarios

Mirrors `AppearanceTests.swift` 1:1.

- **testGoodValuesForThumbnailsWidthMinMax** — for every model × {3,4,5} rows, the computed (min, max) thumbnail width matches the fixture.
- **testComfortableWidth** — for every model, the comfortable width fraction matches for both horizontal and vertical screen use.
- **testComfortableWidthFallsBackToDefaultWhenPhysicalWidthIsNil** — when the screen's physical dimensions aren't reported, fall back to the 0.9 default rather than the 0.45 floor.
- **testGoodValuesForThumbnailsWidthMinMaxPortrait** — for aspectRatio < 1 (portrait usage), the (min, max) uses the portrait formula and stays within the [0.09, 0.30] clamps.

## Thumbnail placeholders

- **testThumbnailPlaceholderReservesKnownWindowGeometryWhileCaptureIsAvailable** — a newly discovered window reserves its final aspect ratio while its first capture is in flight, so replacing the app-icon placeholder does not resize the switcher.
- **testThumbnailPlaceholderUsesIconGeometryWithoutScreenRecording** — an icon-only tile stays square when no window capture can arrive.
- **testThumbnailPlaceholderUsesIconGeometryWithoutValidWindowSize** — unknown or invalid window geometry falls back to the app icon.

The fork's Titles appearance shares its launcher chrome with browser tabs. The frame is at most 750 points wide. Its height grows to fit all rows, up to the screen's usable height with 12 points of clearance at each edge. Lists scroll only beyond that height. A visible borderless search header and a footer action labeled Switch reserve their own space above and below the scrolling list. Recycled title rows use neutral rounded selection, regular text, and a trailing app name. Thumbnails and App Icons retain their own layout and accent selection. Neither panel shows a redundant section subtitle or item count. Search mode and modifier-release behavior follow the existing shortcut configuration.

Return and keypad Enter commit the selected window immediately while its panel is key, including when search has the caret or the activation modifier remains held. An open menu or marked text keeps Return with that interaction. Releasing modifiers retains the configured shortcut behavior.
