#!/usr/bin/env python3
"""
arabfont.py  -  build the arabic font patch for Double Dealers Demo

what it does
------------
  the game font (object FONT67 in sharedassets0.assets) has 421 glyphs
  (latin + cyrillic) on a 2048x2048 SDF atlas.  the arabic text needs 117
  characters that the font does not have.

  instead of growing the file (which would need offsets to be fixed
  everywhere) this tool REUSES the slots of characters that a german /
  english game never shows (the cyrillic block) and

     * overwrites 117 glyph records   (same 52-byte layout, same index)
     * overwrites 117 character records (only the unicode field changes)
     * writes the new glyph bitmaps into the atlas pixels those records
       used to point at  (plus the padding around them)

  so the file keeps its exact size and layout - the patch is a pure
  overwrite of bytes inside two objects.

pixel format (all proven against 418 original glyphs, error < 1.3/255)
---------------------------------------------------------------------
  * SDF rendered by freetype:  set_char_size(0, 128*64, 72, 72),
    FT_RENDER_MODE_SDF  ->  bitmap = ink box + 8 px border, spread 8,
    byte = 128 + 16 * distance
  * the record floats == FreeType metrics in px at em 128
  * the atlas cell == the bitmap minus its 8 px border
  * atlas pixel grid starts at object offset 124
  * a cell (x,y,w,h) lives at rows y..y+h-1 / cols x..x+w-1 but the rows
    are stored upside down:  memory[y+i][x+j] = bitmap[h-1-i][j]

usage
-----
  python3 arabfont.py <FONT67.bin> <payload-out.bin> [--manifest m.json]
"""

import json
import os
import struct
import sys

import numpy as np
import freetype as ft

# ---------------------------------------------------------------- config
FONT_SIZE = 128          # the em size every original glyph was rendered at
PAD = 8                  # freetype sdf border
ATLAS_W = ATLAS_H = 2048
ATLAS_PIXEL_BASE = 124   # offset of the pixel grid inside the atlas object
ATLAS_OBJECT_SIZE = 4194444   # the whole picture object in the game file
GLYPH_TABLE = 436
GLYPH_STRIDE = 52
CHAR_TABLE = 22332
CHAR_STRIDE = 16
GLYPH_COUNT = 421
CHAR_COUNT = 421

SACRIFICE_RANGES = [(0x0400, 0x04FF)]      # cyrillic  (never shown by this game)
KEEP_MARGIN = 8                            # px kept clear around live glyphs (= the atlas padding)
SLOT_GROW = 8                              # px of a dead slot that becomes usable

PAYLOAD_MAGIC = b"DDAF"


# ---------------------------------------------------------------- helpers
def parse_font67(data):
    """-> (glyphs, chars) with glyphs[glyph_index] = dict and chars = list of dicts"""
    glyphs = {}
    for k in range(GLYPH_COUNT):
        o = GLYPH_TABLE + GLYPH_STRIDE * k
        idx = struct.unpack_from("<I", data, o)[0]
        glyphs[idx] = dict(
            rec_off=o,
            index=idx,
            w=struct.unpack_from("<f", data, o + 4)[0],
            h=struct.unpack_from("<f", data, o + 8)[0],
            bx=struct.unpack_from("<f", data, o + 12)[0],
            by=struct.unpack_from("<f", data, o + 16)[0],
            adv=struct.unpack_from("<f", data, o + 20)[0],
            rect=tuple(struct.unpack_from("<i", data, o + 24 + 4 * j)[0] for j in range(4)),
            scale=struct.unpack_from("<f", data, o + 40)[0],
            atlas=struct.unpack_from("<i", data, o + 44)[0],
            pad=struct.unpack_from("<i", data, o + 48)[0],
        )
    chars = []
    for k in range(CHAR_COUNT):
        o = CHAR_TABLE + CHAR_STRIDE * k
        chars.append(dict(rec_off=o,
                          element=struct.unpack_from("<I", data, o)[0],
                          unicode=struct.unpack_from("<I", data, o + 4)[0],
                          glyph=struct.unpack_from("<I", data, o + 8)[0],
                          scale=struct.unpack_from("<f", data, o + 12)[0]))
    return glyphs, chars


def render_cell(face, cp, em=FONT_SIZE, pad=PAD):
    """render one character the way the game font was made.

    returns (cell_bytes uint8 [h,w], w, h, metrics dict) or None
    """
    gi = face.get_char_index(cp)
    if gi == 0:
        return None
    face.set_char_size(0, em * 64, 72, 72)
    face.load_glyph(gi, ft.FT_LOAD_NO_HINTING | ft.FT_LOAD_NO_BITMAP)
    face.glyph.render(ft.FT_RENDER_MODE_SDF)
    b = face.glyph.bitmap
    m = face.glyph.metrics
    buf = np.frombuffer(bytes(b.buffer), np.uint8)[:b.pitch * b.rows]
    buf = buf.reshape(b.rows, b.pitch)[:, :b.width]
    cell = buf[pad:pad + (b.rows - 2 * pad), pad:pad + (b.width - 2 * pad)]
    return (np.ascontiguousarray(cell),
            cell.shape[1], cell.shape[0],
            dict(w=m.width / 64.0, h=m.height / 64.0, bx=m.horiBearingX / 64.0,
                 by=m.horiBearingY / 64.0, adv=m.horiAdvance / 64.0))


# ---------------------------------------------------------------- packing
def build_rooms_mask(glyphs, dead_index, live_index, grow=SLOT_GROW, keep_margin=KEEP_MARGIN):
    """free pixel mask: dead slots grown by `grow`, minus live cells (+ margin)"""
    live = np.zeros((ATLAS_H, ATLAS_W), np.uint8)
    for i in live_index:
        x, y, w, h = glyphs[i]["rect"]
        if w > 0 and h > 0:
            x0, y0 = max(0, x - keep_margin), max(0, y - keep_margin)
            live[y0:y + h + keep_margin, x0:x + w + keep_margin] = 1
    mask = np.zeros((ATLAS_H, ATLAS_W), np.uint8)
    for i in dead_index:
        x, y, w, h = glyphs[i]["rect"]
        if w > 0 and h > 0:
            x0, y0 = max(0, x - grow), max(0, y - grow)
            mask[y0:y + h + grow, x0:x + w + grow] = 1
    return (mask > 0) & (live == 0)


def vertical_runs(free):
    """run[y,x] = number of free pixels from (y,x) downwards (0 where blocked)"""
    h, w = free.shape
    ys = np.arange(h, dtype=np.int32)[:, None]
    blocked = np.where(free, -1, ys)
    # a virtual blocked row right under the image so open columns are handled
    ext = np.vstack([blocked, np.full((1, w), h, np.int32)])
    last = np.maximum.accumulate(ext[::-1], axis=0)[::-1][:h]
    run = last - ys
    run[~free] = 0
    return run


def min_next_w(a, w):
    """out[y,x] = min(a[y, x:x+w])  (positions where the window runs off the
    right edge keep their partial value; they are never used)"""
    out = np.array(a, dtype=np.int32)
    if w <= 1:
        return out
    k = 1
    while k < w:
        s = min(k, w - k)
        merged = out.copy()
        merged[:, :-s] = np.minimum(out[:, :-s], out[:, s:])
        out = merged
        k += s
    return out


def pack(cells, free, verbose=True):
    """first-fit-decreasing on a pixel mask.

    cells: list of (key, w, h)
    returns: dict key -> (x, y, w, h)  (missing keys = could not place)
    """
    free = np.ascontiguousarray(free.astype(bool))
    placed = {}
    order = sorted(cells, key=lambda c: (-c[1] * c[2], -c[2], -c[1]))
    for key, w, h in order:
        if w < 1 or h < 1:
            continue
        runs = vertical_runs(free)
        colmin = min_next_w(runs, w)
        ok = colmin[:, :ATLAS_W - w + 1] >= h
        pos = np.argwhere(ok)
        # keep only positions that really are free (safety net)
        if len(pos):
            good = np.array([free[y:y + h, x:x + w].all() for y, x in pos[::max(1, len(pos) // 3000)]])
            pos = pos[::max(1, len(pos) // 3000)][good]
        if len(pos) == 0:
            if verbose:
                print("   !! %s (%dx%d) does not fit" % (key, w, h))
            continue
        slack = colmin[pos[:, 0], pos[:, 1]] - h
        k = np.lexsort((pos[:, 1], pos[:, 0], slack))[0]   # tightest, then top, then left
        y, x = int(pos[k, 0]), int(pos[k, 1])
        assert free[y:y + h, x:x + w].all()
        placed[key] = (x, y, int(w), int(h))
        free[y:y + h, x:x + w] = False
        if verbose:
            print("   placed %-6s %3dx%-3d at (%4d,%4d)" % (key, w, h, x, y))
    return placed


# ---------------------------------------------------------------- builder
def build(font67_path, font_path, cps_path, payload_path, manifest_path=None, em=FONT_SIZE,
          atlas_head_path=None):
    original = open(font67_path, "rb").read()
    data = bytearray(original)
    glyphs, chars = parse_font67(data)
    cps = json.load(open(cps_path))

    face = ft.Face(font_path)
    cells = {}
    missing = []
    for cp in cps:
        r = render_cell(face, cp, em=em)
        if r is None:
            missing.append(cp)
            continue
        cells[cp] = r
    if missing:
        raise SystemExit("font has no glyph for: %s" % ["%04X" % c for c in missing])

    # --- pick the characters we are allowed to overwrite
    dead, live = [], []
    for idx, g in sorted(glyphs.items()):
        cs = [c for c in chars if c["glyph"] == idx]
        cp = cs[0]["unicode"] if cs else -1
        if any(lo <= cp <= hi for lo, hi in SACRIFICE_RANGES) and g["rect"][2] > 0:
            dead.append(idx)
        else:
            live.append(idx)
    if len(dead) < len(cells):
        raise SystemExit("only %d reusable slots for %d characters" % (len(dead), len(cells)))
    print("reusable slots: %d   live glyphs: %d   characters to add: %d" % (len(dead), len(live), len(cells)))

    # --- pack the new cells into the dead slots (+ their padding)
    free = build_rooms_mask(glyphs, dead, live)
    print("reclaimable area: %d px ; new cells need %d px" % (
        int(free.sum()), sum(c[1] * c[2] for c in cells.values())))
    placed = pack([("%04X" % cp, cells[cp][1], cells[cp][2]) for cp in cells], free)
    if len(placed) != len(cells):
        raise SystemExit("could not place %d of %d characters" % (len(cells) - len(placed), len(cells)))

    # --- write the records
    slot_of = {}                      # cp -> the dead glyph index that hosts it
    for cp, idx in zip(sorted(cells), dead):
        slot_of[cp] = idx
    atlas_writes = []
    for cp in sorted(cells):
        idx = slot_of[cp]
        x, y, w, h = placed["%04X" % cp]
        cell, cw, ch, met = cells[cp]
        assert (cw, ch) == (w, h), (cp, cw, ch, w, h)
        g = glyphs[idx]
        o = g["rec_off"]
        struct.pack_into("<I", data, o, g["index"])                    # index unchanged
        struct.pack_into("<5f", data, o + 4, met["w"], met["h"], met["bx"], met["by"], met["adv"])
        struct.pack_into("<4i", data, o + 24, x, y, w, h)
        struct.pack_into("<f", data, o + 40, 1.0)
        struct.pack_into("<i", data, o + 44, 0)
        struct.pack_into("<i", data, o + 48, 0)
        # the character record that pointed at this glyph now names the arabic character
        cs = [c for c in chars if c["glyph"] == idx]
        if len(cs) != 1:
            raise SystemExit("glyph %d has %d character records" % (idx, len(cs)))
        struct.pack_into("<I", data, cs[0]["rec_off"] + 4, cp)
        # pixels: rows stored upside down
        rows = np.ascontiguousarray(cell[::-1])
        atlas_writes.append((ATLAS_PIXEL_BASE + y * ATLAS_W + x, w, h, rows.tobytes()))
        glyphs[idx]["rect"] = (x, y, w, h)

    # --- sanity: every wanted character is now reachable
    glyphs2, chars2 = parse_font67(bytes(data))
    have = {c["unicode"] for c in chars2}
    for cp in cps:
        if cp not in have:
            raise SystemExit("character %04X is not in the new character table" % cp)
    for cp in cps:
        idx = slot_of[cp]
        r = glyphs2[idx]["rect"]
        if r[2] <= 0 or r[3] <= 0 or r[0] + r[2] > ATLAS_W or r[1] + r[3] > ATLAS_H:
            raise SystemExit("bad rect for %04X: %s" % (cp, r))

    # --- payload (version 2, self describing, gates included)
    import hashlib

    def h32(b):
        return hashlib.sha256(b).hexdigest()

    head = b""
    if atlas_head_path:
        head = open(atlas_head_path, "rb").read()
    body = bytearray()
    body += PAYLOAD_MAGIC
    body += struct.pack("<IIIII", 2, em, ATLAS_W, ATLAS_H, ATLAS_PIXEL_BASE)
    body += struct.pack("<III", ATLAS_OBJECT_SIZE, len(original), len(cps))
    body += struct.pack("<II", len(atlas_writes), 0)
    body += bytes.fromhex(h32(original))                 # font object before
    body += bytes.fromhex(h32(bytes(data)))              # font object after
    body += bytes.fromhex(h32(head))                     # atlas object, first bytes
    body += bytes.fromhex(h32(b"".join(w[3] for w in atlas_writes)))
    body += struct.pack("<II", len(data), len(head))
    body += bytes(data)
    for off, w, h, blob in atlas_writes:
        body += struct.pack("<III", off, w, h)      # rows go to off + i * ATLAS_W
        body += blob
    body += hashlib.sha256(bytes(body)).digest()
    open(payload_path, "wb").write(bytes(body))

    if manifest_path:
        man = dict(font=os.path.basename(font_path), em=em, characters=len(cps),
                   cells=[dict(cp="%04X" % cp, slot=slot_of[cp],
                               pos=placed["%04X" % cp]) for cp in sorted(cells)],
                   font_sha256_before=h32(original), font_sha256_after=h32(bytes(data)),
                   atlas_head_sha256=h32(head), pixels_sha256=h32(b"".join(w[3] for w in atlas_writes)),
                   payload_size=len(body), glyph_count=GLYPH_COUNT, char_count=CHAR_COUNT,
                   atlas_width=ATLAS_W, atlas_height=ATLAS_H,
                   atlas_pixel_base=ATLAS_PIXEL_BASE,
                   pixel_writes=len(atlas_writes), pixel_bytes=sum(len(w[3]) for w in atlas_writes))
        json.dump(man, open(manifest_path, "w"), indent=1)

    print("payload: %s  (%d bytes, %d pixel writes, %d px)" % (
        payload_path, len(body), len(atlas_writes), sum(len(w[3]) for w in atlas_writes)))
    print("font object : before %s  after %s" % (h32(original)[:16], h32(bytes(data))[:16]))
    print("atlas head  : %s   pixels %s" % (h32(head)[:16], h32(b"".join(w[3] for w in atlas_writes))[:16]))
    print("reused slots: %s ... (%d of %d)" % (dead[:5], len(dead), len(dead)))
    return dict(glyphs=glyphs, placed=placed, dead=dead)


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("font67")
    p.add_argument("payload")
    p.add_argument("--font", default=os.path.join(os.path.dirname(__file__), "..", "fonts",
                                                  "arabic-ibmplex-bold.ttf"))
    p.add_argument("--cps", default=os.path.join(os.path.dirname(__file__), "..", "fonts",
                                                 "arabic-needed.json"))
    p.add_argument("--manifest")
    p.add_argument("--em", type=int, default=FONT_SIZE)
    p.add_argument("--atlas-header", default=os.path.join(os.path.dirname(__file__), "..",
                                                          "prebuilt", "atlas-header.bin"))
    a = p.parse_args()
    build(a.font67, a.font, a.cps, a.payload, a.manifest, em=a.em,
          atlas_head_path=a.atlas_header)
