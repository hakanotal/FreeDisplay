#!/usr/bin/env python3
"""Generate the FreeDisplay app icon: the blue-to-purple tile shared with FreeAudio, with a
white monitor matching the `display` menu bar symbol. Its screen shows a brightness fader with
the same pill knob as FreeAudio's equalizer, so the two apps read as one family.
Writes every size into FreeDisplay/Assets.xcassets/AppIcon.appiconset.

    python3 scripts/generate-icon.py             (needs Pillow: pip3 install pillow)
    python3 scripts/generate-icon.py preview.png (writes only a 1024 px preview)
"""

import os
import sys
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
CORNER_RADIUS = int(SIZE * 0.18)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "FreeDisplay", "Assets.xcassets", "AppIcon.appiconset")
SIZES = [16, 32, 64, 128, 256, 512, 1024]

# Monitor geometry, as fractions of the icon size.
BODY = (0.175, 0.235, 0.825, 0.655)   # left, top, right, bottom
BODY_RADIUS = 0.06
BEZEL = 0.034
NECK = (0.462, 0.655, 0.538, 0.735)
BASE = (0.345, 0.722, 0.655, 0.772)


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def gradient(size, top, bottom):
    """Vertical gradient, the same colours as FreeAudio (#4A90D9 → #7B68EE)."""
    img = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        color = tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,)
        draw.line([(0, y), (size, y)], fill=color)
    return img


def box(rect, offset=(0, 0)):
    left, top, right, bottom = rect
    ox, oy = offset
    return [int(SIZE * left + ox), int(SIZE * top + oy), int(SIZE * right + ox), int(SIZE * bottom + oy)]


def monitor_silhouette(offset=(0, 0)):
    """Body, neck and base as one opaque white shape (used for the shadow)."""
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.rounded_rectangle(box(BODY, offset), radius=int(SIZE * BODY_RADIUS), fill=(255, 255, 255, 255))
    draw.rectangle(box(NECK, offset), fill=(255, 255, 255, 255))
    base_h = (BASE[3] - BASE[1]) * SIZE
    draw.rounded_rectangle(box(BASE, offset), radius=int(base_h / 2), fill=(255, 255, 255, 255))
    return layer


def monitor_layer():
    """The white monitor with a dark translucent screen and a brightness fader on it."""
    layer = monitor_silhouette()
    draw = ImageDraw.Draw(layer)

    # Screen: drawn over the white body (pixels are replaced, not blended), so the tile shows
    # through darkened, like a display that is on.
    left, top, right, bottom = BODY
    screen = (left + BEZEL, top + BEZEL, right - BEZEL, bottom - BEZEL)
    draw.rounded_rectangle(box(screen), radius=int(SIZE * (BODY_RADIUS - BEZEL * 0.6)),
                           fill=(22, 26, 78, 120))

    # Brightness fader across the screen: dim track, bright filled part, white pill knob.
    cy = (screen[1] + screen[3]) / 2 + 0.01
    track_h, knob_w, knob_h = 0.046, 0.165, 0.095
    x0, x1, knob_x = 0.30, 0.70, 0.575
    radius = int(SIZE * track_h / 2)
    draw.rounded_rectangle(box((x0, cy - track_h / 2, x1, cy + track_h / 2)), radius=radius,
                           fill=(255, 255, 255, 110))
    draw.rounded_rectangle(box((x0, cy - track_h / 2, knob_x, cy + track_h / 2)), radius=radius,
                           fill=(255, 255, 255, 215))
    return layer, (knob_x, cy, knob_w, knob_h)


def knob_layer(knob, offset=(0, 0)):
    x, y, w, h = knob
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(box((x - w / 2, y - h / 2, x + w / 2, y + h / 2), offset),
                                            radius=int(SIZE * h / 2), fill=(255, 255, 255, 255))
    return layer


def soft_shadow(layer, opacity, blur):
    alpha = layer.split()[3].point(lambda a: int(a * opacity))
    shadow = Image.merge("RGBA", (Image.new("L", layer.size, 0),) * 3 + (alpha,))
    return shadow.filter(ImageFilter.GaussianBlur(SIZE * blur))


def main():
    tile = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    tile.paste(gradient(SIZE, (74, 144, 217), (123, 104, 238)), (0, 0), rounded_mask(SIZE, CORNER_RADIUS))

    # Soft shadow under the monitor, as under FreeAudio's faders.
    tile = Image.alpha_composite(tile, soft_shadow(monitor_silhouette(offset=(0, int(SIZE * 0.018))), 0.28, 0.012))
    monitor, knob = monitor_layer()
    tile = Image.alpha_composite(tile, monitor)
    tile = Image.alpha_composite(tile, soft_shadow(knob_layer(knob, offset=(0, int(SIZE * 0.012))), 0.35, 0.010))
    tile = Image.alpha_composite(tile, knob_layer(knob))

    if len(sys.argv) > 1:
        tile.save(sys.argv[1], "PNG")
        print(f"Saved preview: {sys.argv[1]}")
        return
    for size in SIZES:
        path = os.path.join(ICONSET, f"icon_{size}.png")
        tile.resize((size, size), Image.LANCZOS).save(path, "PNG")
        print(f"Saved: {path}")


if __name__ == "__main__":
    main()
