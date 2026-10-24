#!/usr/bin/env python3
"""Draw the Hamaca hammock mark as SVG, in every variant the icon set needs.

The mark came out of Claude Design (docs/brand/source/hamaca-icon.svg): a barless hammock seen a
little from the side, folded into flat facets. Blue for the belly and the far wall, violet for
the inside of the fold and the end, two short violet ropes, and thin seams between the facets
cut through to the background. Its geometry is kept here verbatim on its own 512 grid.

Seams are a mask, not white strokes, so the mark stays correct on any background (and on
transparency). Run `docs/brand/build.sh` to regenerate the SVGs and every exported PNG.
"""

import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "svg")

# Brand colors: the board's AI violet and human blue, deepened so the icon pops.
VIOLET = "#6339D0"
BLUE = "#1A6EFF"
WHITE = "#FFFFFF"
INK = "#1E252E"     # oklch(0.26 0.02 255), the board's ink
GRAY = "#8A8F99"

# Geometry on the source's 512 grid.
ROPES = "M36 130 L84 166 M476 150 L436 194"
FACETS = [  # (color role, path)
    ("blue", "M84 166 C120 310 250 400 356 350 Z"),                      # belly
    ("violet", "M84 166 L356 350 L420 316 Z"),                           # inside of the fold
    ("blue", "M315 269.1 L436 194 L386.4 301 Z"),                        # far wall
    ("violet", "M292.3 259 L436 194 L315 269.1 Z"),                      # far lip
    ("violet", "M436 194 C437.4 198.6 437.1 207.9 437.1 217.5 C437.1 249.5 429.2 304.6 420 316 "
               "L386.4 301 Z"),                                          # right end
]
SEAMS = "M436 194 L386.4 301 M436 194 L315 269.1 M84 166 L420 316 M84 166 L356 350"
SEAM_W, ROPE_W = 3, 12
# Favicons and legacy Android icons: at 16-48px a 3-unit seam is a fraction of a pixel and the
# facets merge, so seams and ropes get heavier.
SEAM_W_SMALL, ROPE_W_SMALL = 9, 20


def mark(blue, violet, rope, seam_w=SEAM_W, rope_w=ROPE_W):
    """The hammock on the 1024 canvas. Seams are cut out of everything, ropes included."""
    fill = {"blue": blue, "violet": violet}
    facets = "".join(f'<path d="{d}" fill="{fill[role]}"/>' for role, d in FACETS)
    return ('<mask id="seams" maskUnits="userSpaceOnUse" x="-512" y="-512" width="1536" height="1536">'
            '<rect x="-512" y="-512" width="1536" height="1536" fill="#FFFFFF"/>'
            f'<path d="{SEAMS}" stroke="#000000" stroke-width="{seam_w}" stroke-linecap="round" fill="none"/>'
            '</mask>'
            '<g transform="scale(2)" mask="url(#seams)">'
            f'<path d="{ROPES}" stroke="{rope}" stroke-width="{rope_w}" stroke-linecap="round" fill="none"/>'
            f"{facets}</g>")


def svg(content, bg=None, size=1024, scale=1.0, view=1024, rounded=False):
    off = (view - view * scale) / 2
    r = ' rx="230"' if rounded else ""
    bg_el = f'<rect width="{view}" height="{view}"{r} fill="{bg}"/>' if bg else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {view} {view}">'
            f'{bg_el}<g transform="translate({off:.1f} {off:.1f}) scale({scale})">{content}</g></svg>\n')


def og_image(m):
    """1200x630 social share card: mark on the left, name and line on the right."""
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">'
            f'<rect width="1200" height="630" fill="{WHITE}"/>'
            f'<g transform="translate(20 50) scale(0.52)">{m}</g>'
            '<g font-family="Avenir Next, Helvetica Neue, Arial, sans-serif">'
            f'<text x="600" y="290" font-size="112" font-weight="700" letter-spacing="-2" fill="{INK}">Hamaca</text>'
            f'<text x="604" y="370" font-size="38" font-weight="500" fill="{VIOLET}">Hammock Driven Development</text>'
            '</g></svg>\n')


def write(name, text):
    with open(os.path.join(OUT, name), "w") as fh:
        fh.write(text)


def main():
    os.makedirs(OUT, exist_ok=True)
    full = mark(BLUE, VIOLET, VIOLET)
    small = mark(BLUE, VIOLET, VIOLET, SEAM_W_SMALL, ROPE_W_SMALL)
    white = mark(WHITE, WHITE, WHITE)

    # App icon master: opaque, full-bleed square on white (Apple and Google apply their own masks).
    write("app-icon.svg", svg(full, bg=WHITE))
    write("app-icon-small.svg", svg(small, bg=WHITE))
    # iOS 18 dark variant: same mark on the board's ink.
    write("app-icon-dark.svg", svg(full, bg=INK))
    # iOS 18 tinted variant: grayscale on black; iOS tints it.
    write("app-icon-tinted.svg", svg(mark(WHITE, GRAY, GRAY), bg="#000000"))
    # Browser favicon: rounded tile, heavier seams and ropes.
    write("favicon.svg", svg(small, bg=WHITE, rounded=True))
    # The mark alone on transparency: color for light backgrounds, white for dark or colored ones.
    write("mark-color.svg", svg(full))
    write("mark-white.svg", svg(white))
    write("mark-mono.svg", svg(white))
    # Android adaptive layers on a 108dp canvas: the safe zone is a 66dp circle, so the mark is
    # scaled until the rope ends sit inside it.
    write("android-foreground.svg", svg(full, scale=0.56))
    write("android-background.svg", svg("", bg=WHITE))
    write("android-monochrome.svg", svg(mark(WHITE, WHITE, WHITE, SEAM_W_SMALL, ROPE_W_SMALL), scale=0.56))
    # PWA maskable icon: the platform may crop to a circle of 80%, so pull the mark in.
    write("icon-maskable.svg", svg(full, bg=WHITE, scale=0.72))
    write("og-image.svg", og_image(full))


if __name__ == "__main__":
    main()
