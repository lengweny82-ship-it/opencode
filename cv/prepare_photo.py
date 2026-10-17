# -*- coding: utf-8 -*-
"""Prepare the profile photo: square crop + circular mask + gold ring."""

import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
SOURCE = "/tmp/arena-coding-uploads/cv_photo.png"

# square crop around the head and shoulders (x1, y1, x2, y2 in the original)
CROP = (55, 20, 1035, 1000)

NAVY = (16, 36, 64)
GOLD = (162, 128, 64)
WHITE = (255, 255, 255)

OUT_SIZE = 700          # final square canvas
SS = 4                  # supersampling factor


def build():
    src = Image.open(SOURCE).convert("RGB")
    square = src.crop(CROP).resize((OUT_SIZE * SS, OUT_SIZE * SS), Image.LANCZOS)

    size = OUT_SIZE * SS
    center = size / 2

    ring_outer = size / 2 - 2 * SS          # gold ring outer edge
    ring_width = 6 * SS
    ring_inner = ring_outer - ring_width
    gap = 5 * SS
    photo_r = ring_inner - gap

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    # gold ring
    draw.ellipse(
        [center - ring_outer, center - ring_outer, center + ring_outer, center + ring_outer],
        fill=GOLD + (255,),
    )
    # clear the inner area so only the ring band stays
    draw.ellipse(
        [center - ring_inner, center - ring_inner, center + ring_inner, center + ring_inner],
        fill=(0, 0, 0, 0),
    )

    # circular photo
    photo_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(photo_mask).ellipse(
        [center - photo_r, center - photo_r, center + photo_r, center + photo_r], fill=255
    )
    canvas.paste(square, (0, 0), photo_mask)

    final = canvas.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)
    os.makedirs(ASSETS, exist_ok=True)

    # flattened on navy (used inside the header band everywhere)
    flat = Image.new("RGB", (OUT_SIZE, OUT_SIZE), NAVY)
    flat.paste(final, (0, 0), final)
    out = os.path.join(ASSETS, "photo_circle.png")
    flat.save(out, optimize=True)

    # compact JPEG used inside the PDF header
    flat.resize((520, 520), Image.LANCZOS).save(
        os.path.join(ASSETS, "photo_circle_pdf.jpg"), quality=92,
        optimize=True, progressive=True)

    # smaller copy for Word (2.3 cm at ~300 dpi is plenty)
    flat.resize((460, 460), Image.LANCZOS).save(
        os.path.join(ASSETS, "photo_circle_docx.png"), optimize=True)
    print("wrote", out, os.path.getsize(out) // 1024, "KB")

    # preview on navy
    bg = Image.new("RGB", (OUT_SIZE, OUT_SIZE), NAVY)
    bg.paste(final, (0, 0), final)
    bg.save("/tmp/photo_preview.png")

    # also a portrait version for the Word header (same circle)
    return out


if __name__ == "__main__":
    build()
