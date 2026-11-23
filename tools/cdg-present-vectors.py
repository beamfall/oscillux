#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write the CD+G presentation vectors under conformance/cdg-present/.

This is an independent model of conformance/cdg-present/README.md, written from that text in
standard-library Python. It shares no code with the Rust presenter or oscillux-cdg-render. Packs
are decoded with the independent decoder model in tools/cdg-vectors.py (`Model`); seeking back
replays the stream from the start.

It computes differently from a straightforward renderer where it can: the doubled window is kept
as ranks, and a blurred layer mask is evaluated only at the taps a frame samples, as a weighted
count of the 3 x 3 clamped neighbourhood of the doubled image whose rank reaches the layer's rank
(weights 1 4 1 / 4 16 4 / 1 4 1, value `(255 * weight + 18) // 36`, which is exactly the
README's row-then-column [1, 4, 1] blur of 0/255 masks with clamped coordinates). Scenes are
cached by decoder content.

Usage: python3 -I tools/cdg-present-vectors.py
       python3 -I tools/cdg-present-vectors.py --check   (exit 1 if a generated file differs)
       python3 -I tools/cdg-present-vectors.py --frame NAME W H PACKS MILLIS OUT.rgba
           (write the RGBA8 frame of one present at that position on a fresh presenter)
"""

import filecmp
import hashlib
import importlib.util
import os
import sys
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT_DIR = os.path.join(ROOT, "conformance", "cdg-present")
CDG_DIR = os.path.join(ROOT, "conformance", "cdg")


def _load_decoder():
    spec = importlib.util.spec_from_file_location(
        "cdg_vectors", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cdg-vectors.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.Model


Model = _load_decoder()

WIN_W, WIN_H = 288, 192
DW, DH = 576, 384
EDGE_PIXELS = 8928
BAYER = ((0, 8, 2, 10), (12, 4, 14, 6), (3, 11, 1, 9), (15, 7, 13, 5))
GLOWS = ((0, (18, 34), (20, 40), 75, 36000, 23000, 31000),   # colour 0 = light
         (1, (66, 84), (60, 82), 65, 30000, 27000, 37000))   # colour 1 = warm


def div255(x):
    return (x + 128 + ((x + 128) >> 8)) >> 8


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def levels(rgb):
    return ((rgb >> 8) & 15, (rgb >> 4) & 15, rgb & 15)


def trunc_div(a, b):
    """Integer division truncating toward zero."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


# ---------------------------------------------------------------- decoder access

def read_stream(name):
    with open(os.path.join(CDG_DIR, name + ".cdg"), "rb") as f:
        data = f.read()
    return [data[i:i + 24] for i in range(0, len(data) - 23, 24)]


class Decoder:
    """Applies packs of one stream; seeking back replays from the start."""

    def __init__(self, packs):
        self.packs, self.model, self.applied = packs, Model(), 0

    def advance(self, target):
        if target > len(self.packs):
            raise ValueError("position %d past the stream's %d packs" % (target, len(self.packs)))
        if target < self.applied:
            self.model, self.applied = Model(), 0
        while self.applied < target:
            self.model.pack(self.packs[self.applied])
            self.applied += 1

    def window(self):
        m = self.model
        x0, y0 = 6 + m.h, 12 + m.v
        return [m.rows[y][x0:x0 + WIN_W] for y in range(y0, y0 + WIN_H)]


# ---------------------------------------------------------------- per-content scene

def edge_counts(win):
    count = [0] * 16
    for y in range(WIN_H):
        row = win[y]
        if y < 12 or y >= 180:
            for v in row:
                count[v] += 1
        else:
            for v in row[:6]:
                count[v] += 1
            for v in row[282:]:
                count[v] += 1
    assert sum(count) == EDGE_PIXELS
    return count


def background(count, preset):
    if count[preset] * 2 >= EDGE_PIXELS:
        return preset
    best = 0
    for i in range(16):
        if count[i] > count[best]:
            best = i
    return best


def backdrop_set(count, bg):
    return {i for i in range(16) if i == bg or count[i] * 4 >= EDGE_PIXELS}


def ranks(colours, bg):
    out = []
    lb = levels(colours[bg])
    for i in range(16):
        if i == bg:
            out.append(0)
        else:
            li = levels(colours[i])
            out.append(16 * sum((a - b) ** 2 for a, b in zip(li, lb)) + i + 1)
    return out


def scale2x(win, rank):
    """The doubled window as indices, 384 rows of 576."""
    out = []
    for y in range(WIN_H):
        row, up, dn = win[y], win[max(y - 1, 0)], win[min(y + 1, WIN_H - 1)]
        top, bot = [0] * DW, [0] * DW
        for x in range(WIN_W):
            p, a, d = row[x], up[x], dn[x]
            xl, xr = max(x - 1, 0), min(x + 1, WIN_W - 1)
            c, b = row[xl], row[xr]
            tl = tr = bl = br = p
            if not (a == p and b == p and c == p and d == p):
                rp = rank[p]

                def take(q, g):
                    return g != p or rank[q] > rp
                if c == a and c != d and a != b and take(a, up[xl]):
                    tl = a
                if a == b and a != c and b != d and take(b, up[xr]):
                    tr = b
                if d == c and d != b and c != a and take(c, dn[xl]):
                    bl = c
                if b == d and b != a and d != c and take(d, dn[xr]):
                    br = d
            top[2 * x], top[2 * x + 1], bot[2 * x], bot[2 * x + 1] = tl, tr, bl, br
        out.append(top)
        out.append(bot)
    return out


def blur_shadow(m):
    """One pass of the README's shadow blur on a 200 x 296 mask, zero at the border."""
    h = []
    for row in m:
        r = [0] * 296
        for x in range(1, 295):
            r[x] = row[x - 1] + row[x] + row[x + 1]
        h.append(r)
    out = [[0] * 296 for _ in range(200)]
    for y in range(1, 199):
        a, b, c, o = h[y - 1], h[y], h[y + 1], out[y]
        for x in range(296):
            o[x] = (a[x] + b[x] + c[x] + 4) // 9
    return out


# ---------------------------------------------------------------- colours

TARGET = 35 * 1024 // 10


def luminance(rgb):
    r, g, b = rgb
    return (54 * r * r + 183 * g * g + 19 * b * b) >> 8


def contrast(a, b):
    hi, lo = max(a, b), min(a, b)
    return (hi + 3251) * 1024 // (lo + 3251)


def backdrop_range(stage):
    """Luminances bounding the backdrop for an 8.8 stage colour: per-channel extremes over the
    corners of the (light weight, warm weight, vignette) box."""
    base = [v * 230 // 1024 + 1536 for v in stage]
    light = [lighten(v, 180) for v in stage]
    warm = [lighten((stage[c] + stage[(c + 2) % 3]) // 2, 80) for c in range(3)]
    lo, hi = [None] * 3, [0] * 3
    for corner in range(8):
        c = list(base)
        for bit, (colour, strength) in enumerate(((light, 36000), (warm, 30000))):
            a = strength if corner >> bit & 1 else 0
            c = [c[ch] + (((colour[ch] - c[ch]) * a) >> 16) for ch in range(3)]
        v = 35536 if corner & 4 else 65536
        for ch in range(3):
            px = min(max((c[ch] * v) >> 16, 0), 65280) >> 8
            lo[ch] = px if lo[ch] is None else min(lo[ch], px)
            hi[ch] = max(hi[ch], px)
    return luminance(lo), luminance(hi)


def worst(l, dark, bright):
    if dark <= l <= bright:
        return 1024
    return min(contrast(l, dark), contrast(l, bright))


def legible(rgb, dark, bright):
    best = (worst(luminance(rgb), dark, bright), rgb)
    if best[0] >= TARGET:
        return rgb
    for k in range(1, 17):
        for c in (tuple(v + (255 - v) * k // 16 for v in rgb),
                  tuple(v * (16 - k) // 16 for v in rgb)):
            w = worst(luminance(c), dark, bright)
            if w >= TARGET:
                return c
            if w > best[0]:
                best = (w, c)
    return best[1]


def boundaries(win, colours, backdrop):
    """Window boundary length of each graphics index with the backdrop, and of each ordered
    pair of graphics indices that contrast with each other (README, Colours)."""
    lum = [luminance(tuple(l * 17 for l in levels(c))) for c in colours]
    back, held = [0] * 16, {}

    def pair(a, b):
        if a == b:
            return
        ba, bb = a in backdrop, b in backdrop
        if ba and bb:
            return
        if bb:
            back[a] += 1
        elif ba:
            back[b] += 1
        elif contrast(lum[a], lum[b]) >= TARGET:
            held[(a, b)] = held.get((a, b), 0) + 1
            held[(b, a)] = held.get((b, a), 0) + 1

    for y in range(WIN_H):
        row = win[y]
        for x in range(WIN_W):
            if x + 1 < WIN_W:
                pair(row[x], row[x + 1])
            if y + 1 < WIN_H:
                pair(row[x], win[y + 1][x])
    return back, held


class Scene:
    """Everything that depends only on the decoder's window, colours and preset."""

    def __init__(self, win, colours, preset):
        count = edge_counts(win)
        self.bg = background(count, preset)
        self.backdrop = backdrop_set(count, self.bg)
        self.rank = rank = ranks(colours, self.bg)
        self.colours = colours
        self.doubled = scale2x(win, rank)
        present = set()
        for row in self.doubled:
            present.update(row)
        layers = sorted((i for i in present if i not in self.backdrop), key=lambda i: rank[i])
        self.layers = layers
        self.layer_ranks = [rank[i] for i in layers]
        self.back_len, self.held = boundaries(win, colours, self.backdrop)
        # Backdrop pixels never count toward a layer (README, Layers).
        self.drank = [[0 if v in self.backdrop else rank[v] for v in row] for row in self.doubled]
        self.values = {}
        ink = [i not in self.backdrop and (rank[i] - 1) >> 4 >= 12 for i in range(16)]
        m = [[0] * 296 for _ in range(200)]
        any_ink = False
        for y in range(WIN_H):
            row, mrow = win[y], m[y + 4]
            for x in range(WIN_W):
                if ink[row[x]]:
                    mrow[x + 4] = 255
                    any_ink = True
        if any_ink:
            m = blur_shadow(blur_shadow(m))
        self.shadow = m

    def layer_values(self, x, y):
        """Blurred mask value of every layer at doubled (x, y): weighted 3 x 3 clamped neighbourhood."""
        key = y * DW + x
        got = self.values.get(key)
        if got is None:
            xs = (max(x - 1, 0), x, min(x + 1, DW - 1))
            neigh = []
            for yy in (max(y - 1, 0), y, min(y + 1, DH - 1)):
                r = self.drank[yy]
                neigh += (r[xs[0]], r[xs[1]], r[xs[2]])
            got = [(255 * sum(w for q, w in zip(neigh, WEIGHTS) if q >= lr) + 18) // 36
                   for lr in self.layer_ranks]
            self.values[key] = got
        return got


# README, Layers: the [1, 4, 1] row-then-column blur as 3 x 3 weights, row-major.
WEIGHTS = (1, 4, 1, 4, 16, 4, 1, 4, 1)

SCENES = {}


def scene_for(decoder):
    m = decoder.model
    win = decoder.window()
    key = (tuple(m.colours), m.preset, bytes(v for row in win for v in row))
    s = SCENES.get(key)
    if s is None:
        s = SCENES[key] = Scene(win, list(m.colours), m.preset)
    return s


# ---------------------------------------------------------------- geometry

def geometry(w, h):
    if 2 * w >= 3 * h:
        rw, rh = (3 * h + 1) // 2, h
        return rw, rh, (w - rw) // 2, 0
    rw, rh = w, max(2 * w // 3, 1)
    return rw, rh, 0, (h - rh) // 2


def tap(t, s, n, size, k, f, last):
    d = t - s
    pos = clamp(((2 * d + 1) * size * 65536) // (2 * n) - 32768 + k, 0, last * 65536)
    i0 = pos >> 16
    i1 = min(i0 + 1, last)
    frac = (pos & 0xFFFF) >> 8
    if d < 0 or d >= n:
        edge = 0
    elif f == 0:
        edge = 256
    else:
        e = min(d, n - 1 - d)
        edge = min((2 * e + 1) * 128 // f, 256)
    return i0, i1, frac, edge


def graphics_taps(cells, s, n, size, f):
    return [tap(t, s, n, size, 0, f, size - 1) for t in range(cells)]


def shadow_taps(cells, s, n, size, last):
    out = []
    for t in range(cells):
        i0, i1, frac, edge = tap(t, s, n, size, 4 * 65536 - 65536, 0, last)
        if edge == 0:
            i0 = i1 = frac = 0
        out.append((i0, i1, frac))
    return out


# ---------------------------------------------------------------- stage and backdrop

def drift(t, p):
    u = t % p
    tri = abs(trunc_div(2 * u * 65536, p) - 65536)
    return (((tri * tri) >> 16) * (196608 - 2 * tri)) >> 16


def lighten(v, k):
    return v + (65280 - v) * k // 1024


def backdrop_rows(w, h, stage, millis):
    base = [stage[c] * 230 // 1024 + 1536 for c in range(3)]
    light = [lighten(stage[c], 180) for c in range(3)]
    warm = [lighten((stage[c] + stage[(c + 2) % 3]) // 2, 80) for c in range(3)]
    big = max(w, h)
    glows = []
    for which, (x0, x1), (y0, y1), radius, strength, px, py in GLOWS:
        cx = w * (x0 + (x1 - x0) * drift(millis, px) // 65536) // 100
        cy = h * (y0 + (y1 - y0) * drift(millis + px // 3, py) // 65536) // 100
        r = max(big * radius // 100, 1)
        glows.append((light if which == 0 else warm, cx, cy, (1 << 32) // (r * r), strength))
    hw, hh = w // 2, h // 2
    corner = max(hw * hw + hh * hh, 1)

    def at(x, y):
        c = list(base)
        for colour, cx, cy, inv, strength in glows:
            d2 = (x - cx) ** 2 + (y - cy) ** 2
            q = 65536 - min((d2 * inv) >> 16, 65536)
            a = (((q * q) >> 16) * strength) >> 16
            for ch in range(3):
                c[ch] += ((colour[ch] - c[ch]) * a) >> 16
        v = 65536 - 30000 * ((x - hw) ** 2 + (y - hh) ** 2) // corner
        return [clamp((c[ch] * v) >> 16, 0, 65280) for ch in range(3)]

    samples = list(range(0, w, 8))
    if samples[-1] != w - 1:
        samples.append(w - 1)
    rows = []
    for y in range(h):
        vals = [at(x, y) for x in samples]
        row = [None] * w
        for j, x in enumerate(samples):
            row[x] = vals[j]
        for j in range(len(samples) - 1):
            xa, xb, a, b = samples[j], samples[j + 1], vals[j], vals[j + 1]
            span = xb - xa
            for t in range(1, span):
                row[xa + t] = [(a[ch] * (span - t) + b[ch] * t + span // 2) // span
                               for ch in range(3)]
        rows.append(row)
    return rows


class Presenter:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.first = True
        self.frm = self.to = self.stage = None
        self.start = self.last = 0
        rw, rh, rx, ry = geometry(w, h)
        self.rw = rw
        self.gx = graphics_taps(w, rx, rw, DW, rw * 6 // 288)
        self.gy = graphics_taps(h, ry, rh, DH, rh * 12 // 192)
        self.sx = shadow_taps(w, rx, rw, WIN_W, 295)
        self.sy = shadow_taps(h, ry, rh, WIN_H, 199)
        self.ramp = max(rw * 256 // 150, 388)
        self.protected = set()
        self.built = None

    def colours(self, sc):
        """README, Colours: the drawn 8-bit RGB of every index."""
        key = (sc.bg, tuple(sc.colours))
        if self.built is not None and self.built != key:
            self.protected = set()
        self.built = key
        rgb = [tuple(l * 17 for l in levels(c)) for c in sc.colours]
        lum = [luminance(c) for c in rgb]
        dark, bright = backdrop_range(tuple((l * 17) << 8 for l in levels(sc.colours[sc.bg])))
        ok = [worst(l, dark, bright) >= TARGET for l in lum]
        for (i, j), n in sc.held.items():
            if ok[j] and n * 3 >= sc.back_len[i]:
                self.protected.add(i)
        return [legible(rgb[i], dark, bright)
                if sc.back_len[i] > 0 and not ok[i] and i not in self.protected else rgb[i]
                for i in range(16)]

    def ease(self, target, millis):
        if self.first or millis < self.last:
            self.frm = self.to = target
            self.start = millis
        elif target != self.to:
            self.frm, self.to, self.start = self.stage, target, millis
        self.first = False
        t = clamp(millis - self.start, 0, 300)
        self.stage = tuple(f + trunc_div((o - f) * t, 300) for f, o in zip(self.frm, self.to))
        self.last = millis

    def present(self, decoder, millis):
        sc = scene_for(decoder)
        target = tuple((c * 17) << 8 for c in levels(sc.colours[sc.bg]))
        self.ease(target, millis)
        w, h = self.w, self.h
        back = backdrop_rows(w, h, self.stage, millis)
        shadow, gx, gy, sx, sy = sc.shadow, self.gx, self.gy, self.sx, self.sy
        drawn = self.colours(sc)
        lcol = [drawn[i] + (255,) for i in sc.layers]
        nlayers, ramp, values = len(sc.layer_ranks), self.ramp, sc.layer_values
        out = bytearray(w * h * 4)
        o = 0
        for y in range(h):
            brow, bayer = back[y], BAYER[y % 4]
            sy0, sy1, sfy = sy[y]
            srow0, srow1 = shadow[sy0], shadow[sy1]
            gy0, gy1, fy, ey = gy[y]
            for x in range(w):
                sx0, sx1, sfx = sx[x]
                top = srow0[sx0] * (256 - sfx) + srow0[sx1] * sfx
                bot = srow1[sx0] * (256 - sfx) + srow1[sx1] * sfx
                m = (top * (256 - sfy) + bot * sfy) >> 16
                keep = 255 - div255(m * 110)
                g = [0, 0, 0, 0]
                gx0, gx1, fx, ex = gx[x]
                edge = ex * ey
                if edge:
                    v00, v10 = values(gx0, gy0), values(gx1, gy0)
                    v01, v11 = values(gx0, gy1), values(gx1, gy1)
                    # Only taps with nonzero bilinear weight decide whether a layer differs.
                    used = (True, fx != 0, fy != 0, fx != 0 and fy != 0)

                    def weighted(li):
                        q = (v00[li], v10[li], v01[li], v11[li])
                        return tuple(t for t, u in zip(q, used) if u)

                    for li in range(nlayers):
                        a, b, c, d = v00[li], v10[li], v01[li], v11[li]
                        if a == 0 and b == 0 and c == 0 and d == 0:
                            break
                        if li + 1 < nlayers and weighted(li + 1) == weighted(li):
                            continue
                        top = a * (256 - fx) + b * fx
                        bot = c * (256 - fx) + d * fx
                        v = (top * (256 - fy) + bot * fy) >> 8
                        cov = clamp((((v - 171 * 256) * ramp) >> 16) + 128, 0, 255)
                        if cov > 0:
                            p = lcol[li]
                            g = [div255(p[ch] * cov + g[ch] * (255 - cov)) for ch in range(4)]
                    g = [(g[ch] * edge + 32768) >> 16 for ch in range(4)]
                bk = brow[x]
                bay = bayer[x % 4] * 16 + 8
                inv_a = 255 - g[3]
                for ch in range(3):
                    s = min((bk[ch] + bay) >> 8, 255)
                    out[o + ch] = min(g[ch] + div255(div255(s * keep) * inv_a), 255)
                out[o + 3] = 255
                o += 4
        return bytes(out)


# ---------------------------------------------------------------- vectors

def ms(packs):
    return packs * 10 // 3


def spread(count, n):
    """About n positions spread over 1..count, ascending, ending at count."""
    return sorted({max(1, count * k // n) for k in range(1, n + 1)})


def bg_changes(packs):
    """Positions after which the background index differs from the position before."""
    dec, prev, out = Decoder(packs), None, []
    for p in range(len(packs) + 1):
        dec.advance(p)
        count = edge_counts(dec.window())
        bg = background(count, dec.model.preset)
        if prev is not None and bg != prev:
            out.append(p)
        prev = bg
    return out


def frames_for(name, packs):
    count = len(packs)
    frames = [(p, ms(p)) for p in spread(count, 6)]
    # Backdrop drift only: same position, later media time.
    p_last, m_last = frames[-1]
    frames.append((p_last, m_last + 1234))
    # A backwards seek: fewer packs and an earlier time.
    back = max(1, count // 3)
    frames.append((back, ms(back) + 50))
    if name == "presets":
        # Background changes: settle on the old background, then sample the change and 100
        # and 200 ms into the easing. Times keep rising after the seek so nothing resets.
        t = m_last + 2000
        for p in bg_changes(packs)[:3]:
            frames += [(p - 1, t), (p - 1, t + 400), (p, t + 410), (p, t + 510), (p, t + 610)]
            t += 1000
    # Drift periods wrap.
    frames.append((count, 61000 + 3 * 23000 + 777))
    return frames


STREAMS = ("karaoke-blue", "karaoke-tiles", "presets", "scroll")
SIZES = ((192, 108), (90, 150), (7, 5))
# One wide frame per stream covers the steeper coverage ramp (rw >= 600), and one at exactly
# twice the window, where every tap fraction is zero, covers unweighted taps.
WIDE = ((600, 400), (576, 384))


def expect(name, head):
    packs = read_stream(name)
    lines = [head, "# stream %s.cdg, %d packs" % (name, len(packs))]
    dec = Decoder(packs)
    for p in spread(len(packs), 8):
        dec.advance(p)
        count = edge_counts(dec.window())
        bg = background(count, dec.model.preset)
        mask = sum(1 << i for i in backdrop_set(count, bg))
        lines.append("bg %d %d %04x" % (p, bg, mask))
    frames = frames_for(name, packs)
    nframes = 0
    for w, h in SIZES:
        lines.append("size %d %d" % (w, h))
        presenter, dec = Presenter(w, h), Decoder(packs)
        for p, millis in frames:
            dec.advance(p)
            rgba = presenter.present(dec, millis)
            lines.append("frame %d %d %s" % (p, millis, hashlib.sha256(rgba).hexdigest()))
            nframes += 1
    for w, h in WIDE:
        lines.append("size %d %d" % (w, h))
        presenter, dec = Presenter(w, h), Decoder(packs)
        p, millis = frames[len(frames) // 2]
        dec.advance(p)
        rgba = presenter.present(dec, millis)
        lines.append("frame %d %d %s" % (p, millis, hashlib.sha256(rgba).hexdigest()))
        nframes += 1
    return "\n".join(lines) + "\n", nframes


def generate(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    head = ("# cdg-present-vectors: tools/cdg-present-vectors.py "
            "(independent model of conformance/cdg-present/README.md)")
    total = 0
    for name in STREAMS:
        text, n = expect(name, head)
        with open(os.path.join(out_dir, name + ".expect"), "w") as f:
            f.write(text)
        total += n
        print("%-13s %3d frames" % (name, n))
    print("%d frames" % total)


def check():
    generated = lambda d: [n for n in os.listdir(d) if n.endswith(".expect")]
    with tempfile.TemporaryDirectory() as fresh:
        generate(fresh)
        wanted = sorted(generated(fresh))
        have = sorted(generated(OUT_DIR)) if os.path.isdir(OUT_DIR) else []
        _, changed, errors = filecmp.cmpfiles(fresh, OUT_DIR, wanted, shallow=False)
    missing = [n for n in wanted if n not in have]
    extra = [n for n in have if n not in wanted]
    problems = [(k, v) for k, v in (("changed", changed), ("missing", missing),
                                    ("not generated", extra),
                                    ("unreadable", [n for n in errors if n not in missing])) if v]
    if problems:
        sys.exit("conformance/cdg-present/ differs from tools/cdg-present-vectors.py; "
                 "regenerate it\n" +
                 "\n".join("%s: %s" % (k, ", ".join(v)) for k, v in problems))
    print("conformance/cdg-present/: %d files match the generator" % len(wanted))


def frame(name, w, h, packs, millis, path):
    dec = Decoder(read_stream(name))
    dec.advance(packs)
    rgba = Presenter(w, h).present(dec, millis)
    with open(path, "wb") as f:
        f.write(rgba)


def main():
    args = sys.argv[1:]
    if args == ["--check"]:
        check()
    elif len(args) == 7 and args[0] == "--frame":
        w, h = int(args[2]), int(args[3])
        if not (1 <= w <= 8192 and 1 <= h <= 8192):
            sys.exit("W and H must be 1..8192")
        frame(args[1], w, h, int(args[4]), int(args[5]), args[6])
    elif args:
        sys.exit("usage: python3 -I tools/cdg-present-vectors.py "
                 "[--check | --frame NAME W H PACKS MILLIS OUT.rgba]")
    else:
        generate(OUT_DIR)


if __name__ == "__main__":
    main()
