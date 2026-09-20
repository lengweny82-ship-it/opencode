#!/usr/bin/env python3
"""TMP (TextMeshPro) font asset helpers.

Conventions recovered from the game's own Nunito-ExtraBold SDF asset:
  * atlas pixel format  : Alpha8, 2048x2048, 4,194,304 bytes
  * SDF value           : v = 128 + 128 * d / spread      (d = signed distance in px)
                          0 at d = -spread, 255 at d = +spread
  * rect fields         : glyphRect = (x, y, w, h) - bitmap box in texture space (y from bottom)
  * storage             : raw texture rows are bottom-up (row 0 = bottom of the image)
"""
import ctypes
import numpy as np
import freetype as ft
from scipy import ndimage

# ----------------------------------------------------------------- glyph rendering
def load_face(path):
    return ft.Face(path)

def _render_mask(face, cp, em_px, ss=8):
    """render a glyph as an anti-aliased coverage mask at em_px * ss"""
    face.set_char_size(0, int(em_px * ss * 64), 72, 72)
    face.load_char(cp, ft.FT_LOAD_RENDER | ft.FT_LOAD_NO_HINTING | ft.FT_LOAD_NO_BITMAP)
    slot = face.glyph
    m = slot.metrics
    left_ss = m.horiBearingX / 64.0        # in ss pixels
    top_ss = m.horiBearingY / 64.0
    adv_ss = m.horiAdvance / 64.0
    bmp = slot.bitmap
    if bmp.rows == 0 or bmp.width == 0:
        return None, left_ss, top_ss, adv_ss
    pitch = bmp.pitch
    buf = np.frombuffer(bytes(bmp.buffer), dtype=np.uint8)[:pitch * bmp.rows].reshape(bmp.rows, pitch)
    return buf[:, :bmp.width].astype(np.float32) / 255.0, left_ss, top_ss, adv_ss


def glyph_sdf(face, cp, em_px, spread, ss=8, pad=None, size_scale=1.0):
    """returns dict(alpha, left, top, advance, w, h)

    alpha : uint8 SDF bitmap, row 0 = top of the glyph box
    left  : x of the box's left edge relative to the pen position (px)
    top   : y of the box's top edge relative to the baseline (px, up positive)
    pad   : extra empty pixels around the ink (defaults to the SDF spread)
    """
    if pad is None:
        pad = int(np.ceil(spread))
    em = em_px * size_scale
    cov, left_ss, top_ss, adv_ss = _render_mask(face, cp, em, ss)
    adv = adv_ss / ss
    if cov is None:
        return dict(alpha=np.zeros((1, 1), np.uint8), left=0, top=0, advance=adv, w=1, h=1, empty=True)
    h_ss, w_ss = cov.shape
    left_px, top_px = left_ss / ss, top_ss / ss
    w_px, h_px = w_ss / ss, h_ss / ss
    x0 = int(np.floor(left_px)) - pad
    y1 = int(np.ceil(top_px)) + pad
    w = int(np.ceil(left_px + w_px)) + pad - x0
    h = y1 - (int(np.floor(top_px - h_px)) - pad)
    # signed distance at ss scale
    mask = cov >= 0.5
    if mask.any() and (~mask).any():
        d_ss = ndimage.distance_transform_edt(mask) - ndimage.distance_transform_edt(~mask)
    elif mask.any():
        d_ss = ndimage.distance_transform_edt(mask)
    else:
        d_ss = -ndimage.distance_transform_edt(~mask)
    # paste into a padded canvas whose top-left corner is the box's top-left
    dx = int(round((x0 - left_px) * ss))
    dy = int(round((y1 - top_px) * ss))
    cw, ch = w * ss, h * ss
    canvas = np.zeros((ch + max(0, -dy), cw + max(0, -dx)), np.float32)
    sy, sx = max(0, dy), max(0, dx)
    canvas[sy:sy + h_ss, sx:sx + w_ss] = d_ss
    pad_h = (h - canvas.shape[0] // ss) * ss
    pad_w = (w - canvas.shape[1] // ss) * ss
    if pad_h > 0 or pad_w > 0:
        canvas = np.pad(canvas, ((0, max(0, pad_h)), (0, max(0, pad_w))), mode='edge')
    blocks = canvas[:h * ss, :w * ss].reshape(h, ss, w, ss).mean(axis=(1, 3)) / ss
    alpha = np.clip(np.rint(128.0 + 128.0 * blocks / spread), 0, 255).astype(np.uint8)
    return dict(alpha=alpha, left=x0, top=y1, advance=adv, w=w, h=h, empty=False)


# ----------------------------------------------------------------- atlas placement
class Packer:
    """simple shelf packer over the free areas of the existing atlas"""
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.rows = []          # (y, x_cursor, row_height)

    def place(self, bw, bh, avoid):
        """avoid = function(x, y, w, h) -> True when the box is free"""
        raise NotImplementedError

# ----------------------------------------------------------------- font object model
import struct

class FontObject:
    """parse / rebuild a TMP_FontAsset object payload"""
    def __init__(self, data):
        self.raw = bytearray(data)
        d = self.raw
        u32 = lambda p: struct.unpack_from('<I', d, p)[0]
        i32 = lambda p: struct.unpack_from('<i', d, p)[0]
        f32 = lambda p: struct.unpack_from('<f', d, p)[0]
        # glyph table: find count+first record by scanning from 200
        self.g0 = None
        for p in range(200, 4096, 4):
            n = i32(p)
            if n < 50 or n > 20000:
                continue
            s = p + 4
            if s + 52 * 2 > len(d):
                continue
            if u32(s) == 1 and u32(s + 52) == 2 and i32(s + 44) == 0 and i32(s + 52 + 44) == 0:
                self.g0 = p
                break
        if self.g0 is None:
            raise ValueError('glyph table not found')
        self.nglyphs = i32(self.g0)
        self.glyphs = []
        for k in range(self.nglyphs):
            o = self.g0 + 4 + 52 * k
            self.glyphs.append(dict(
                idx=u32(o),
                metrics=(f32(o + 4), f32(o + 8), f32(o + 12), f32(o + 16), f32(o + 20)),
                rect=tuple(i32(o + 24 + i * 4) for i in range(4)),
                scale=f32(o + 40), atlas=i32(o + 44), cls=i32(o + 48)))
        self.c0 = self.g0 + 4 + 52 * self.nglyphs
        self.nchars = i32(self.c0)
        self.chars = []
        for k in range(self.nchars):
            o = self.c0 + 4 + 16 * k
            self.chars.append(dict(elem=u32(o), unicode=u32(o + 4), glyph=u32(o + 8),
                                   scale=f32(o + 12)))
        self.a0 = self.c0 + 4 + 16 * self.nchars      # atlas texture info
        self.tail = bytes(d[self.a0:])
        self.head = bytes(d[:self.g0])                # everything before the glyph table

    def describe(self):
        print('glyph table at', self.g0, 'count', self.nglyphs)
        print('char  table at', self.c0, 'count', self.nchars)
        print('atlas info at ', self.a0, 'bytes', len(self.raw) - self.a0)
        print('head bytes', self.g0)

    def rebuild(self, extra_glyphs, extra_chars, atlas_blob):
        """returns a new bytearray of exactly len(self.raw) bytes"""
        out = bytearray()
        out += self.head
        gl = self.glyphs + extra_glyphs
        out += struct.pack('<i', len(gl))
        for g in gl:
            out += struct.pack('<I5f4if', g['idx'], *g['metrics'], *g['rect'], g['scale'], g['atlas'], g['cls'])
        ch = self.chars + extra_chars
        out += struct.pack('<i', len(ch))
        for c in ch:
            out += struct.pack('<IIIf', c['elem'], c['unicode'], c['glyph'], c['scale'])
        out += atlas_blob
        if len(out) > len(self.raw):
            raise ValueError('new object is %d bytes bigger than the original' % (len(out) - len(self.raw)))
        out += b'\x00' * (len(self.raw) - len(out))
        return out
