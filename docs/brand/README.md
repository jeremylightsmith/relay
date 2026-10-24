# Hamaca brand assets

Relay is now **Hamaca** (hamaca.app). The name, the picture and the story are in
[`../marketing/brandscript.md`](../marketing/brandscript.md).

## The mark

A barless hammock seen a little from the side, folded into flat facets: blue for the belly and
the far wall, violet for the inside of the fold and the end, two short violet ropes. Thin seams
between the facets are cut through to the background. It was drawn in Claude Design; the
original is kept in [`source/hamaca-icon.svg`](source/hamaca-icon.svg), and `make_icons.py`
carries its geometry verbatim.

| Color | Hex | Use |
|---|---|---|
| Blue | `#1A6EFF` | belly and far wall (the board's human color, deepened) |
| Violet | `#6339D0` | inside of the fold, the end and the ropes (the board's AI color, deepened) |
| White | `#FFFFFF` | icon background |
| Ink | `#1E252E` | dark icon variant, wordmark |

## Regenerating

`./build.sh` (needs `rsvg-convert` and ImageMagick). It runs `make_icons.py`, which writes the SVG
masters to `svg/`, then exports every PNG to `exports/`. To change the shape or colors, edit the
constants at the top of `make_icons.py` (or replace `source/hamaca-icon.svg` and copy its paths in) and rebuild. Never hand-edit an export.

## What's in `exports/`

- `ios/`: `AppIcon-1024.png` (opaque master; Xcode's single-size app icon), plus the iOS 18
  `-dark` and `-tinted` variants.
- `android/`: `mipmap-*/` with adaptive `ic_launcher_foreground` / `_background` / `_monochrome`
  layers (108dp, mark inside the safe zone) and a legacy `ic_launcher.png`; `play-store-512.png`.
- `web/`: `favicon.svg`, `favicon-16/32/48.png`, `favicon.ico`, `apple-touch-icon.png` (180),
  `icon-192.png`, `icon-512.png`, `icon-maskable-512.png`, and `og-image.png` (1200×630 share card).
- `brand/`: the mark alone on transparency, in color (for light backgrounds), white, and a solid
  single-color silhouette.

Small sizes (favicons, legacy Android) use heavier seams and ropes, because a 3-unit seam is a
fraction of a pixel below about 48px and the facets merge.
