#!/usr/bin/env python3
"""Draw the iPhone Use app icon: a glowing HUD ring around a voice waveform.

Writes the 1024px app icon. Run Scripts/make-runner-icons.py afterwards to
regenerate the runner's icons from it:

    uv run --with pillow python Scripts/make-app-icon.py
    uv run --with pillow python Scripts/make-runner-icons.py
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "iCTRLApp/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png"

SIZE = 1024
SS = 2  # draw at 2x, then downscale for smooth edges
S = SIZE * SS
C = S // 2
CYAN = (46, 230, 255)


def background() -> Image.Image:
    """Radial gradient from deep navy in the centre to near black at the edge."""
    img = Image.new("RGB", (S, S))
    px = img.load()
    inner, outer = (16, 34, 64), (3, 6, 14)
    max_r = math.hypot(C, C)
    for y in range(0, S, 2):
        for x in range(0, S, 2):
            t = min(math.hypot(x - C, y - C) / max_r, 1) ** 0.9
            color = tuple(int(inner[i] * (1 - t) + outer[i] * t) for i in range(3))
            px[x, y] = px[x + 1, y] = px[x, y + 1] = px[x + 1, y + 1] = color
    return img


def ring_layer() -> Image.Image:
    """The HUD: a segmented outer ring, a thin inner ring, and tick marks."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    r_outer = int(S * 0.39)
    w_outer = int(S * 0.028)
    box = (C - r_outer, C - r_outer, C + r_outer, C + r_outer)
    # Four long arcs with gaps, like a targeting reticle.
    for start in (12, 102, 192, 282):
        d.arc(box, start, start + 66, fill=CYAN + (255,), width=w_outer)
    r_inner = int(S * 0.315)
    d.ellipse((C - r_inner, C - r_inner, C + r_inner, C + r_inner),
              outline=CYAN + (150,), width=int(S * 0.008))
    # Tick marks between the two rings.
    for i in range(60):
        a = math.radians(i * 6)
        long = i % 5 == 0
        r1 = r_inner + int(S * 0.018)
        r2 = r1 + int(S * (0.03 if long else 0.016))
        d.line((C + r1 * math.cos(a), C + r1 * math.sin(a), C + r2 * math.cos(a), C + r2 * math.sin(a)),
               fill=CYAN + (200 if long else 110,), width=int(S * (0.006 if long else 0.004)))
    return layer


def wave_layer() -> Image.Image:
    """Seven rounded bars of a voice waveform in the centre."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    heights = [0.10, 0.20, 0.32, 0.42, 0.32, 0.20, 0.10]
    bar_w = int(S * 0.034)
    gap = int(S * 0.026)
    total = len(heights) * bar_w + (len(heights) - 1) * gap
    x = C - total // 2
    for h in heights:
        half = int(S * h / 2)
        d.rounded_rectangle((x, C - half, x + bar_w, C + half), radius=bar_w // 2, fill=(235, 252, 255, 255))
        x += bar_w + gap
    return layer


def glow(layer: Image.Image, radius: int, strength: float) -> Image.Image:
    blurred = layer.filter(ImageFilter.GaussianBlur(radius))
    alpha = blurred.getchannel("A").point(lambda a: int(min(255, a * strength)))
    blurred.putalpha(alpha)
    return blurred


def main() -> None:
    img = background().convert("RGBA")
    rings = ring_layer()
    wave = wave_layer()
    for layer in (glow(rings, S // 40, 1.6), rings, glow(wave, S // 30, 1.8), wave):
        img.alpha_composite(layer)
    # iOS composites a transparent icon on black; ship it opaque.
    img = img.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print(f"wrote {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
