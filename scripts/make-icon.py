#!/usr/bin/env python3
"""Generate UsageBar's app icon (.icns) and menu bar glyph (template PNG).

Design: a thick donut ring — the same shape the popover uses — with a coral arc for
"used" and a jade arc for "left", on a near-black squircle. The menu bar variant is a
monochrome template image (alpha only) so macOS tints it for light/dark menu bars.

    python3 scripts/make-icon.py

Writes Sources/UsageBar/Resources/{AppIcon.icns,MenuBarIcon.png,MenuBarIcon@2x.png}
and build/AppIcon.iconset/. Pillow only.
"""
from __future__ import annotations

import math
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT_RES = ROOT / "Sources/UsageBar/Resources"
BG_TOP = (32, 33, 36)
BG_BOTTOM = (16, 16, 18)
CORAL = (255, 107, 90)
JADE = (53, 208, 165)
RING_TRACK = (92, 94, 100)
S = 1024          # master canvas
SS = 4            # supersample factor for the ring edges


def squircle(size: int, n: float = 5.0) -> Image.Image:
    """Superellipse mask — the actual macOS icon silhouette, not a rounded rect."""
    import numpy as np

    y, x = np.ogrid[-1:1:complex(size), -1:1:complex(size)]
    inside = (np.abs(x) ** n + np.abs(y) ** n) <= 1.0
    mask = (inside * 255).astype("uint8")
    img = Image.fromarray(mask, mode="L")
    return img.resize((size * SS, size * SS), Image.LANCZOS).resize((size, size), Image.LANCZOS)


def vertical_gradient(size: int, top, bottom) -> Image.Image:
    img = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(1, size - 1)
        img.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img.resize((size, size), Image.BILINEAR)


def ring(size: int, line: float, arcs: list[tuple[float, float, tuple[int, int, int]]],
         track: tuple[int, int, int] | None, inset: float = 0.0) -> Image.Image:
    """Draw a donut: `arcs` are (start_deg, end_deg, color), 0° = 12 o'clock, clockwise."""
    big = size * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = line * SS / 2 + inset * big
    box = [pad, pad, big - 1 - pad, big - 1 - pad]
    if track is not None:
        d.ellipse(box, outline=track + (255,), width=round(line * SS))
    for start, end, color in arcs:
        d.arc(box, start=start - 90, end=end - 90, fill=color + (255,), width=round(line * SS))
    return img.resize((size, size), Image.LANCZOS)


def app_icon(size: int = S) -> Image.Image:
    # macOS grid: artwork occupies 824 of the 1024 canvas, transparent margin around it.
    body = round(size * 824 / 1024)
    base = vertical_gradient(body, BG_TOP, BG_BOTTOM).convert("RGBA")
    base.putalpha(squircle(body))

    # Very soft top highlight; anything stronger turns to noise at 16px.
    glow = Image.new("RGBA", (body, body), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([body * 0.12, -body * 0.30, body * 0.88, body * 0.40], fill=(255, 255, 255, 10))
    base.alpha_composite(glow)

    # Gauge, no track: two arcs separated by equal 12° gaps, so the ring stays legible
    # when it shrinks to 16px and the background stops reading as a "broken" donut.
    dial = ring(body, line=body * 0.13, track=None,
                arcs=[(6, 258, CORAL), (270, 354, JADE)], inset=0.06)
    # Center tick, wide enough to survive 16px. Vertically centered (0.5).
    mark = Image.new("RGBA", (body * SS, body * SS), (0, 0, 0, 0))
    md = ImageDraw.Draw(mark)
    w = body * SS * 0.085
    md.rounded_rectangle([body * SS / 2 - w / 2, body * SS * 0.36,
                          body * SS / 2 + w / 2, body * SS * 0.64],
                         radius=w / 2, fill=(245, 245, 247, 255))
    base.alpha_composite(mark.resize((body, body), Image.LANCZOS))
    base.alpha_composite(dial)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - body) // 2
    canvas.alpha_composite(base, (off, off))
    return canvas


def small_icon(px: int) -> Image.Image:
    """Optical sizing for 16/32px.

    Two arcs collapse into a single blob at 16px, so the small variant drops the second
    color and the center pill: one thick coral ring, one clean gap, one white dot.
    """
    size = px * 8
    body = round(size * 0.88)
    base = Image.new("RGBA", (body, body), (26, 26, 29, 255))
    base.putalpha(squircle(body))
    # Ring thin enough to leave a real hole at 16px (inner radius ≥1.5px), gap 22°.
    dial = ring(body, line=body * 0.16, track=None,
                arcs=[(11, 349, CORAL)], inset=0.04)
    base.alpha_composite(dial)

    dot = Image.new("RGBA", (body * SS, body * SS), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dot)
    r = body * SS * 0.085
    c = body * SS / 2
    dd.ellipse([c - r, c - r, c + r, c + r], fill=(245, 245, 247, 255))
    base.alpha_composite(dot.resize((body, body), Image.LANCZOS))

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - body) // 2
    canvas.alpha_composite(base, (off, off))
    return canvas.resize((px, px), Image.LANCZOS)


def menu_bar_glyph(px: int) -> Image.Image:
    """Template image: black pixels + alpha. macOS tints it for the menu bar."""
    size = px * 8
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = size * 0.14
    box = [pad, pad, size - pad, size - pad]
    w = round(size * 0.13)
    d.ellipse(box, outline=(0, 0, 0, 70), width=w)          # faint full track
    d.arc(box, start=-90, end=178, fill=(0, 0, 0, 255), width=w)   # 268° arc
    d.arc(box, start=190, end=262, fill=(0, 0, 0, 255), width=w)   # 72° arc
    w2 = size * 0.10
    d.rounded_rectangle([size / 2 - w2 / 2, size * 0.40, size / 2 + w2 / 2, size * 0.60],
                        radius=w2 / 2, fill=(0, 0, 0, 255))
    return img.resize((px, px), Image.LANCZOS)


def main() -> None:
    OUT_RES.mkdir(parents=True, exist_ok=True)
    iconset = ROOT / "build/AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True)

    master = app_icon(S)
    for name, px in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                     ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                     ("icon_256x256", 256), ("icon_256x256@2x", 512),
                     ("icon_512x512", 512), ("icon_512x512@2x", 1024)]:
        src = small_icon(px) if px <= 32 else master.resize((px, px), Image.LANCZOS)
        src.save(iconset / f"{name}.png")

    icns = OUT_RES / "AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)

    menu_bar_glyph(18).save(OUT_RES / "MenuBarIcon.png")
    menu_bar_glyph(36).save(OUT_RES / "MenuBarIcon@2x.png")
    menu_bar_glyph(1024).save(ROOT / "build/icon-preview.png")
    master.save(ROOT / "build/icon-1024.png")

    print(f"wrote {icns} ({icns.stat().st_size} bytes)")
    for f in sorted(OUT_RES.iterdir()):
        print(f"  {f.relative_to(ROOT)}  {f.stat().st_size} bytes")


if __name__ == "__main__":
    main()
