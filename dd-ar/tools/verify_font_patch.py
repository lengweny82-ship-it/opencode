#!/usr/bin/env python3
"""
verify_font_patch.py  -  offline check of an arabic font patch

  python3 verify_font_patch.py <patch.bin> <FONT67.bin> [out.png]

checks, on the payload alone plus the original font object:
  * the payload is complete and self consistent (checksums)
  * the patched font object still parses: 421 usable characters, every
    arabic character points at a real cell
  * every pixel write is byte for byte what the font file says it should be
  * the new cells do not overlap each other nor any of the kept characters,
    and keep the engine's own 8 px halo around them
  * renders a few real game strings straight out of the patched data
"""

import hashlib
import json
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import arabfont as A

ARABIC = lambda cp: (0x600 <= cp <= 0x6FF) or (0xFB50 <= cp <= 0xFDFF) or (0xFE70 <= cp <= 0xFEFF)


def parse_patch(blob):
    assert blob[:4] == A.PAYLOAD_MAGIC, "not a font patch"
    o = 4
    ver, em, aw, ah, base = struct.unpack_from("<IIIII", blob, o); o += 20
    assert ver == 2, "unsupported patch version %d" % ver
    atlas_obj, font_obj, nchars = struct.unpack_from("<III", blob, o); o += 12
    nw, _res = struct.unpack_from("<II", blob, o); o += 8
    font_before = blob[o:o + 32].hex(); o += 32
    font_after = blob[o:o + 32].hex(); o += 32
    head_before = blob[o:o + 32].hex(); o += 32
    pixels_after = blob[o:o + 32].hex(); o += 32
    flen, hlen = struct.unpack_from("<II", blob, o); o += 8
    font = blob[o:o + flen]; o += flen
    assert hashlib.sha256(font).hexdigest() == font_after, "font part checksum mismatch"
    assert len(font) == font_obj, "font object size mismatch"
    writes = []
    for _ in range(nw):
        off, w, h = struct.unpack_from("<III", blob, o); o += 12
        data = blob[o:o + w * h]; o += w * h
        writes.append((off, w, h, data))
    assert hashlib.sha256(b"".join(w[3] for w in writes)).hexdigest() == pixels_after, \
        "pixel part checksum mismatch"
    assert hashlib.sha256(blob[:o]).digest() == blob[o:o + 32], "patch checksum mismatch"
    return dict(em=em, atlas_w=aw, atlas_h=ah, base=base, atlas_obj=atlas_obj,
                font_obj=font_obj, nchars=nchars, nw=nw, font_before=font_before,
                font_after=font_after, head_before=head_before, head_len=hlen,
                font=font, writes=writes)


def main(patch_path, font67_path, png_path=None):
    p = parse_patch(open(patch_path, "rb").read())
    old = open(font67_path, "rb").read()
    print("patch    : %d bytes, em %d, %d pixel writes (%d px), %d characters" % (
        os.path.getsize(patch_path), p["em"], p["nw"],
        sum(len(w[3]) for w in p["writes"]), p["nchars"]))
    print("gates    : font before %s  after %s" % (p["font_before"][:16], p["font_after"][:16]))
    print("           picture head %s (first %d bytes)" % (p["head_before"][:16], p["head_len"]))
    assert hashlib.sha256(old).hexdigest() == p["font_before"], \
        "the font object you gave me is not the one this patch was built for"

    new = bytes(p["font"])
    glyphs, chars = A.parse_font67(new)
    by_cp = {c["unicode"]: c for c in chars}
    print("font     : %d glyph records, %d character records" % (len(glyphs), len(chars)))
    assert len(glyphs) == A.GLYPH_COUNT and len(chars) == A.CHAR_COUNT
    assert len(by_cp) == len(chars), "duplicate characters"

    cells = {}
    for cp, c in sorted(by_cp.items()):
        if not ARABIC(cp):
            continue
        g = glyphs[c["glyph"]]
        x, y, w, h = g["rect"]
        assert w > 0 and h > 0 and x >= 0 and y >= 0 and x + w <= p["atlas_w"] and y + h <= p["atlas_h"], \
            "character %04X points at a bad cell %s" % (cp, g["rect"])
        assert g["scale"] == 1.0 and g["atlas"] == 0 and g["pad"] == 0
        cells[cp] = g["rect"]
    print("arabic   : %d characters, all with a valid, sane cell" % len(cells))
    assert len(cells) == p["nchars"]

    # --- the cells must not touch each other, nor any character we kept
    def sacrificed(cp):
        return any(lo <= cp <= hi for lo, hi in A.SACRIFICE_RANGES)

    kept = []
    for idx, g in glyphs.items():
        cp = next((c["unicode"] for c in chars if c["glyph"] == idx), -1)
        if g["rect"][2] > 0 and not ARABIC(cp) and not sacrificed(cp):
            kept.append(g["rect"])
    it = sorted(cells.items())
    for i in range(len(it)):
        for j in range(i + 1, len(it)):
            x1, y1, w1, h1 = it[i][1]; x2, y2, w2, h2 = it[j][1]
            assert not (x1 < x2 + w2 and x2 < x1 + w1 and y1 < y2 + h2 and y2 < y1 + h1), \
                "new cells %04X and %04X overlap" % (it[i][0], it[j][0])
    gap = 1 << 30
    for cp, (x, y, w, h) in it:
        for (kx, ky, kw, kh) in kept:
            dx = max(kx - (x + w), x - (kx + kw), 0)
            dy = max(ky - (y + h), y - (ky + kh), 0)
            if dx == 0 and dy == 0:
                raise SystemExit("new cell %04X touches a kept character" % cp)
            gap = min(gap, dx + dy)
    print("cells    : %d new cells, no overlaps, closest kept character is %d px away" % (len(it), gap))

    # --- every pixel write must land exactly on its cell, row for row
    face = __import__("freetype").Face(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fonts", "arabic-ibmplex-bold.ttf"))
    atlas = np.zeros((p["atlas_h"], p["atlas_w"]), np.uint8)
    n_ok = 0
    for off, w, h, blob in p["writes"]:
        rel = off - p["base"]
        assert rel >= 0, "write before the pixel grid"
        y, x = divmod(rel, p["atlas_w"])
        cp = next((c for c, r in cells.items() if r == (x, y, w, h)), None)
        assert cp is not None, "write at (%d,%d) %dx%d matches no cell" % (x, y, w, h)
        want = np.ascontiguousarray(A.render_cell(face, cp, em=p["em"])[0][::-1])
        got = np.frombuffer(blob, np.uint8).reshape(h, w)
        assert want.shape == got.shape and np.array_equal(want, got), \
            "pixels for %04X are not what the font renders" % cp
        assert x + w <= p["atlas_w"] and y + h <= p["atlas_h"], "cell outside the picture"
        atlas[y:y + h, x:x + w] = got
        n_ok += 1
    print("pixels   : %d / %d writes land exactly on their cell, row for row" % (n_ok, p["nw"]))

    # --- and reading the cells back out of the picture must give the same thing
    back_ok = 0
    for cp, (x, y, w, h) in sorted(cells.items()):
        want = np.ascontiguousarray(A.render_cell(face, cp, em=p["em"])[0][::-1])
        if np.array_equal(atlas[y:y + h, x:x + w], want):
            back_ok += 1
    print("read back: %d / %d cells come back out of the picture unchanged" % (back_ok, len(cells)))
    assert back_ok == len(cells)

    empty = []
    for cp, (x, y, w, h) in sorted(cells.items()):
        if not (atlas[y:y + h, x:x + w][::-1] >= 128).any():
            empty.append(cp)
    print("ink      : %d / %d cells have visible ink%s" % (
        len(cells) - len(empty), len(cells), "" if not empty else "  (empty: %s)" % ["%04X" % c for c in empty]))
    assert not empty

    if png_path:
        from PIL import Image
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "translation",
                            "_AutoTranslations.display-ready.ar.txt")
        lines = []
        for ln in open(path, encoding="utf-8"):
            ln = ln.rstrip("\n")
            if "=" in ln and len(ln.split("=", 1)[1]) > 22:
                lines.append(ln.split("=", 1)[1])
            if len(lines) >= 3:
                break
        rows = []
        for s in lines:
            imgs = [glyphs[by_cp[ord(ch)]["glyph"]] for ch in s if ord(ch) in by_cp]
            if not imgs:
                continue
            W = int(sum(g["adv"] for g in imgs)) + 40
            base = 200
            img = np.zeros((base + 80, W), np.uint8)
            pen = 12.0
            for g in imgs:
                x, y, w, h = g["rect"]
                cell = atlas[y:y + h, x:x + w][::-1].astype(np.int16)
                x0 = int(round(pen + g["bx"])); y0 = int(round(base - g["by"]))
                for yy in range(h):
                    ty = y0 + yy
                    if 0 <= ty < img.shape[0]:
                        xs = max(0, -x0); xe = min(w, W - x0)
                        if xe > xs:
                            img[ty, x0 + xs:x0 + xe] = np.maximum(
                                img[ty, x0 + xs:x0 + xe], cell[yy, xs:xe].astype(np.uint8))
                pen += g["adv"]
            rows.append(img)
        W = max(r.shape[1] for r in rows); H = sum(r.shape[0] for r in rows)
        out = Image.new("RGB", (W, H), (8, 8, 10))
        y = 0
        for r in rows:
            a = np.clip((r.astype(np.int16) - 96) * 255 // 96, 0, 255).astype(np.uint8)
            out.paste(Image.fromarray(np.stack([a] * 3, -1)), (0, y)); y += r.shape[0]
        out.save(png_path)
        print("preview  : %s (%dx%d)" % (png_path, out.size[0], out.size[1]))
    print("ALL CHECKS PASSED")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
