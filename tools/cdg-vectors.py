#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write the CD+G decoder vectors under conformance/cdg/.

This is an independent model of the CD+G TV-graphics decoder described in
conformance/cdg/README.md, written from that text in standard-library Python. It shares no code
with the Rust decoder in crates/oscillux-core/src/cdg/ and computes differently where it can: the
screen is a list of rows of ints, scrolls build new rows by slicing instead of rotating in place,
a 12-bit colour is read as `(byte0 << 6) | byte1` instead of channel by channel, the window is
read through explicit coordinates, the alpha of the transparent-colour table is rounded half up
in integer form, digests are SHA-256 (hashlib), and it only ever decodes sequentially (the Rust
tests seek).

Every stream is synthetic: hand-built packs for each instruction and edge case, plus pseudo-random
streams from a fixed 64-bit LCG (`lcg_stream`, specified in the README so the Rust tests can
regenerate the 5-minute stream instead of committing 2 MB). No commercial karaoke data is used.

Outputs, per stream NAME:
  NAME.cdg     the pack stream (not written for the generated-only 5-minute stream)
  NAME.expect  `state` lines at sampled positions, `rgba` lines for the transparency keys and,
               for the realistic streams, `counts` lines

`lyrics` is a synthetic lyric screen (block letters in bright, mid and dark colours on a
transparent colour 0) that tools/shader/cdg-check.mjs composites over every bundled visual.
`karaoke-blue` and `karaoke-tiles` are realistic screens built the way karaoke encoders build
them (`Painter`): blue backgrounds from Memory Preset or from two shades of tiles, lyrics with a
dark outline and a colour wipe; their vectors add mask keys and per-index pixel counts.

Usage: python3 -I tools/cdg-vectors.py
       python3 -I tools/cdg-vectors.py --check   (exit 1 if a generated file differs)
       python3 -I tools/cdg-vectors.py --window NAME KEY
           (write NAME's final 288 x 192 RGBA8 window under KEY, e.g. table or mask:0006,
           to stdout)
"""

import filecmp
import hashlib
import os
import sys
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT_DIR = os.path.join(ROOT, "conformance", "cdg")

W, H = 300, 216
WIN_W, WIN_H = 288, 192
MASK64 = (1 << 64) - 1
LCG_A, LCG_C = 6364136223846793005, 1442695040888963407

MEMORY, BORDER, TILE, XOR, SPRESET, SCOPY, TRANSP, LOW, HIGH = 1, 2, 6, 38, 20, 24, 28, 30, 31


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Model:
    """Sequential CD+G TV-graphics decoder."""

    def __init__(self):
        self.rows = [[0] * W for _ in range(H)]
        self.colours = [0] * 16          # 12-bit 0xRGB
        self.transparent = [0] * 16
        self.h = self.v = self.preset = self.border = 0

    def pack(self, p):
        if p[0] % 64 != 9:
            return
        d = [b % 64 for b in p[4:20]]
        ins = p[1] % 64
        if ins == MEMORY:
            self.preset = d[0] % 16
            self.rows = [[self.preset] * W for _ in range(H)]
        elif ins == BORDER:
            c = self.border = d[0] % 16
            for y in range(H):
                if 12 <= y < 204:
                    self.rows[y][0:6] = [c] * 6
                    self.rows[y][294:300] = [c] * 6
                else:
                    self.rows[y] = [c] * W
        elif ins in (TILE, XOR):
            c0, c1, row, col = d[0] % 16, d[1] % 16, d[2] % 32, d[3]
            if row > 17 or col > 49:
                return
            for r in range(12):
                for c in range(6):
                    on = d[4 + r] & (32 >> c)
                    colour = c1 if on else c0
                    y, x = row * 12 + r, col * 6 + c
                    self.rows[y][x] = (self.rows[y][x] ^ colour) if ins == XOR else colour
        elif ins in (SPRESET, SCOPY):
            fill = d[0] % 16 if ins == SPRESET else None
            hcmd, vcmd = d[1] // 16 % 4, d[2] // 16 % 4
            rows = self.rows
            if hcmd == 1:
                rows = [(r[-6:] if fill is None else [fill] * 6) + r[:-6] for r in rows]
            elif hcmd == 2:
                rows = [r[6:] + (r[:6] if fill is None else [fill] * 6) for r in rows]
            if vcmd == 1:
                rows = (rows[-12:] if fill is None else [[fill] * W for _ in range(12)]) + rows[:-12]
            elif vcmd == 2:
                rows = rows[12:] + (rows[:12] if fill is None else [[fill] * W for _ in range(12)])
            self.rows = [list(r) for r in rows]
            self.h = min(d[1] % 8, 5)
            self.v = min(d[2] % 16, 11)
        elif ins == TRANSP:
            self.transparent = d[:]
        elif ins in (LOW, HIGH):
            base = 0 if ins == LOW else 8
            for i in range(8):
                self.colours[base + i] = (d[2 * i] << 6) | d[2 * i + 1]

    def state_line(self, applied):
        screen = bytes(v for row in self.rows for v in row)
        return "state %d %s %s %s %d %d %d %d" % (
            applied, digest(screen), "".join("%03x" % c for c in self.colours),
            "".join("%02x" % t for t in self.transparent), self.h, self.v, self.preset,
            self.border)

    def window(self, key):
        pixel = []
        for i in range(16):
            rgb = self.colours[i]
            if key == "none":
                a = 255
            elif key == "table":
                a = (2 * (63 - self.transparent[i]) * 255 + 63) // 126
            elif key == "preset":
                a = 0 if i == self.preset else 255
            elif key.startswith("mask:"):
                a = 0 if int(key[5:], 16) >> i & 1 else 255
            else:
                a = 0 if i == int(key.split(":")[1]) else 255
            pixel.append(bytes([(rgb >> s) % 16 * 255 // 15 for s in (8, 4, 0)] + [a]))
        x0, y0 = 6 + self.h, 12 + self.v
        return b"".join(pixel[self.rows[y][x]] for y in range(y0, y0 + WIN_H)
                        for x in range(x0, x0 + WIN_W))

    def rgba_line(self, applied, key):
        return "rgba %d %s %s" % (applied, key, digest(self.window(key)))

    def counts(self, region):
        x0, y0 = 6 + self.h, 12 + self.v
        n = [0] * 16
        for y in range(WIN_H):
            for x in range(WIN_W):
                if region == "window" or not (6 <= x < WIN_W - 6 and 12 <= y < WIN_H - 12):
                    n[self.rows[y0 + y][x0 + x]] += 1
        return n

    def counts_line(self, applied, region):
        return "counts %d %s %s" % (applied, region, ",".join(map(str, self.counts(region))))


class Lcg:
    def __init__(self, seed):
        self.s = seed & MASK64

    def next(self):
        self.s = (self.s * LCG_A + LCG_C) & MASK64
        return self.s >> 32


KNOWN = (MEMORY, BORDER, TILE, XOR, SPRESET, SCOPY, TRANSP, LOW, HIGH)


def lcg_stream(seed, count):
    """The README's pseudo-random stream: every byte random, then command and instruction set."""
    rng, out = Lcg(seed), bytearray()
    table = ((500, None), (800, TILE), (900, XOR), (930, LOW), (960, HIGH), (970, TRANSP),
             (980, SCOPY), (988, SPRESET), (993, MEMORY), (997, BORDER), (1000, "unknown"))
    for _ in range(count):
        p = [rng.next() & 0xFF for _ in range(24)]
        sel = rng.next() % 1000
        kind = next(k for limit, k in table if sel < limit)
        if kind is None:
            cmd = rng.next() & 0x3F
            p[0] = (p[0] & 0xC0) | (0 if cmd == 9 else cmd)
        else:
            p[0] = (p[0] & 0xC0) | 9
            if kind == "unknown":
                ins = rng.next() & 0x3F
                kind = 0 if ins in KNOWN else ins
            p[1] = (p[1] & 0xC0) | kind
        out += bytes(p)
    return bytes(out)


def pk(ins, data=(), cmd=9, hi=(0, 0), junk=None):
    """One pack: instruction `ins`, data symbols, optional high bits on bytes 0/1 and parity."""
    d = list(data) + [0] * (16 - len(data))
    j = junk or [0] * 6
    return bytes([cmd | hi[0], ins | hi[1], j[0], j[1]] + d + j[2:6])


def colours(ins, rgb):
    data = []
    for c in rgb:
        data += [c >> 6, c & 63]
    return pk(ins, data)


def tile(ins, c0, c1, row, col, bits):
    return pk(ins, [c0, c1, row, col] + list(bits))


def scroll(ins, colour, hcmd, hoff, vcmd, voff):
    return pk(ins, [colour, hcmd << 4 | hoff, vcmd << 4 | voff])


def pattern(seed):
    rng = Lcg(seed)
    return [rng.next() & 63 for _ in range(12)]


PALETTE = [colours(LOW, [0x000, 0xFFF, 0xF00, 0x0F0, 0x00F, 0xFF0, 0x0FF, 0xF0F]),
           colours(HIGH, [0x123, 0x456, 0x789, 0xABC, 0xDEF, 0x8F1, 0x3C7, 0xE52])]


def stream_presets():
    rng = Lcg(11)
    junk = [[rng.next() & 0xFF for _ in range(6)] for _ in range(8)]
    return PALETTE + [
        pk(MEMORY, [3, 0]), pk(MEMORY, [3, 1]), pk(MEMORY, [3, 2], junk=junk[0]),
        tile(TILE, 1, 2, 5, 10, pattern(1)),
        pk(MEMORY, [3, 3]),                      # a repeat still clears (README)
        tile(TILE, 4, 5, 0, 0, pattern(2)), tile(TILE, 6, 7, 17, 49, pattern(3)),
        pk(BORDER, [7]),
        pk(MEMORY, [0x3C | 0xC0, 15], junk=junk[1]),   # data masked to 0x3C, colour 12
        tile(TILE, 9, 10, 1, 1, pattern(4)),
        pk(BORDER, [0x31], hi=(0xC0, 0x40), junk=junk[2]),  # 0xC9/0x42 still Border Preset 1
        pk(MEMORY, [5, 0], hi=(0x80, 0x80)),
        pk(BORDER, [14]),
    ]


def stream_tiles():
    packs = PALETTE + [pk(MEMORY, [2, 0]), pk(BORDER, [9])]
    places = [(0, 0), (0, 49), (17, 0), (17, 49), (8, 25), (1, 0), (16, 48)]
    for n, (row, col) in enumerate(places):
        packs.append(tile(TILE, n % 16, (n * 5 + 3) % 16, row, col, pattern(20 + n)))
    # Out of range rows and columns are ignored; masked high bits bring 0x25 to row 5.
    packs += [tile(TILE, 1, 2, 18, 3, pattern(30)), tile(TILE, 1, 2, 31, 3, pattern(31)),
              tile(TILE, 1, 2, 3, 50, pattern(32)), tile(TILE, 1, 2, 3, 63, pattern(33)),
              tile(TILE, 3, 4, 0x25, 7, pattern(34)), tile(TILE, 0x3F, 0x30, 2, 0x28, pattern(35)),
              tile(TILE, 0, 0, 9, 9, [63] * 12), tile(TILE, 0, 15, 9, 10, [63] * 12),
              tile(TILE, 15, 0, 9, 11, [0] * 12), tile(TILE, 5, 6, 9, 12, [0x2A, 0x15] * 6)]
    rng = Lcg(36)
    for _ in range(40):
        packs.append(pk(TILE, [rng.next() & 0xFF for _ in range(16)],
                        junk=[rng.next() & 0xFF for _ in range(6)]))
    return packs


def stream_xor():
    packs = PALETTE + [pk(MEMORY, [1, 0])]
    for n in range(6):
        packs.append(tile(TILE, n, n + 6, n, n * 3, pattern(40 + n)))
    for n in range(6):
        packs.append(tile(XOR, (n * 7) % 16, (n * 3 + 1) % 16, n, n * 3, pattern(50 + n)))
    # XOR twice with the same tile restores the screen.
    packs += [tile(XOR, 9, 6, 4, 4, pattern(60)), tile(XOR, 9, 6, 4, 4, pattern(60)),
              tile(XOR, 0, 15, 17, 49, [63] * 12), tile(XOR, 15, 0, 17, 49, [63] * 12),
              tile(XOR, 3, 12, 0, 0, pattern(61)), tile(XOR, 1, 2, 18, 0, pattern(62))]
    rng = Lcg(63)
    for _ in range(30):
        packs.append(pk(XOR, [rng.next() & 0xFF for _ in range(16)]))
    return packs


def stream_scroll():
    packs = PALETTE + [pk(MEMORY, [0, 0]), pk(BORDER, [4])]
    for n in range(24):
        packs.append(tile(TILE, n % 16, (n + 7) % 16, (n * 5) % 18, (n * 11) % 50, pattern(70 + n)))
    for ins in (SCOPY, SPRESET):
        for hcmd in range(4):
            for vcmd in range(4):
                packs.append(scroll(ins, (hcmd * 4 + vcmd) % 16, hcmd, hcmd + vcmd, vcmd,
                                    3 * vcmd + hcmd))
    packs += [scroll(SCOPY, 0, 0, off, 0, 0) for off in range(8)]
    packs += [scroll(SCOPY, 0, 0, 0, 0, off) for off in range(16)]
    packs += [scroll(SCOPY, 0, 1, 2, 0, 5) for _ in range(50)]     # full horizontal wrap
    packs += [scroll(SCOPY, 0, 0, 0, 2, 7) for _ in range(18)]     # full vertical wrap
    packs += [scroll(SPRESET, 13, 2, 1, 1, 9), scroll(SPRESET, 6, 1, 4, 2, 2),
              pk(SCOPY, [0xFF, 0xFF, 0xFF]), pk(SPRESET, [0xC5, 0x9F, 0x6E])]
    return packs


def stream_palette():
    packs = [pk(MEMORY, [0, 0])]
    for n in range(16):
        packs.append(tile(TILE, n, 15 - n, n % 18, n * 3, pattern(100 + n)))
    rng = Lcg(117)
    for _ in range(8):
        packs.append(pk(LOW, [rng.next() & 0xFF for _ in range(16)]))
        packs.append(pk(HIGH, [rng.next() & 0xFF for _ in range(16)]))
    packs += PALETTE
    packs += [pk(TRANSP, [0] * 16), pk(TRANSP, [63] * 16), pk(TRANSP, [i * 4 for i in range(16)]),
              pk(TRANSP, [63 - i * 4 for i in range(16)], junk=[1, 2, 3, 4, 5, 6]),
              pk(TRANSP, [0xC0 | (i * 13 % 64) for i in range(16)]),
              colours(LOW, [0xFFF] * 8), PALETTE[0]]
    return packs


def stream_ignored():
    packs = PALETTE + [pk(MEMORY, [6, 0]), tile(TILE, 1, 2, 3, 4, pattern(140))]
    for cmd in (0x00, 0x08, 0x0A, 0x38, 0x3F, 0x89, 0xC8):
        for ins in (MEMORY, TILE, SCOPY, LOW):
            packs.append(pk(ins, [9, 9, 9, 9] + [63] * 12, cmd=cmd & 0x3F, hi=(cmd & 0xC0, 0)))
    for ins in (0, 3, 7, 21, 25, 29, 32, 39, 63):
        packs.append(pk(ins, [9, 9, 9, 9] + [63] * 12))
    packs.append(bytes(24))
    packs.append(bytes([0x49, 0x46, 0xFF, 0xFF, 1, 2, 3, 4] + [63] * 12 + [0xFF] * 4))  # 0x49 is TV graphics
    return packs


# 5 x 7 block letters, drawn in columns 0..4 and rows 3..9 of a 6 x 12 tile.
FONT = {
    "A": ".###. #...# #...# ##### #...# #...# #...#",
    "B": "####. #...# #...# ####. #...# #...# ####.",
    "C": ".#### #.... #.... #.... #.... #.... .####",
    "D": "####. #...# #...# #...# #...# #...# ####.",
    "E": "##### #.... #.... ####. #.... #.... #####",
    "G": ".#### #.... #.... #.### #...# #...# .###.",
    "H": "#...# #...# #...# ##### #...# #...# #...#",
    "I": "##### ..#.. ..#.. ..#.. ..#.. ..#.. #####",
    "K": "#...# #..#. #.#.. ##... #.#.. #..#. #...#",
    "L": "#.... #.... #.... #.... #.... #.... #####",
    "N": "#...# ##..# #.#.# #..## #...# #...# #...#",
    "O": ".###. #...# #...# #...# #...# #...# .###.",
    "R": "####. #...# #...# ####. #.#.. #..#. #...#",
    "S": ".#### #.... #.... .###. ....# ....# ####.",
    "T": "##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..",
    "U": "#...# #...# #...# #...# #...# #...# .###.",
    "V": "#...# #...# #...# #...# #...# .#.#. ..#..",
    "X": "#...# #...# .#.#. ..#.. .#.#. #...# #...#",
    "Y": "#...# #...# .#.#. ..#.. ..#.. ..#.. ..#..",
}
# Colour 0 is the transparent background; the rest span bright, mid-grey and dark text.
LYRIC_COLOURS = [colours(LOW, [0x000, 0xFFF, 0xFF0, 0x0FF, 0xF8C, 0x027, 0xF00, 0x00F]),
                 colours(HIGH, [0x777, 0x2A2, 0x888, 0x000, 0x000, 0x000, 0x000, 0x000])]
# (row, column, [(text, colour)]) in tiles.
LYRIC_LINES = [(2, 4, [("SING", 2), (" ALONG", 1)]), (4, 4, [("OSCILLUX CDG", 3)]),
               (6, 4, [("LYRIC HALO", 4)]), (8, 4, [("DARK NAVY", 5)]),
               (10, 4, [("RED TEXT", 6)]), (12, 4, [("BLUE TEXT", 7)]),
               (14, 4, [("GREY", 8), (" GREEN", 9), (" SILVER", 10)])]


def glyph(letter):
    rows = [0] * 12
    for r, bits in enumerate(FONT[letter].split()):
        rows[3 + r] = sum(1 << (5 - c) for c, b in enumerate(bits) if b == "#")
    return rows


def stream_lyrics():
    packs = LYRIC_COLOURS + [pk(MEMORY, [0, 0]), pk(BORDER, [0]), pk(TRANSP, [63] + [0] * 15)]
    for row, col, runs in LYRIC_LINES:
        for text, colour in runs:
            for letter in text:
                if letter != " ":
                    packs.append(tile(TILE, 0, colour, row, col, glyph(letter)))
                col += 1
    packs.append(scroll(SPRESET, 0, 0, 3, 0, 4))    # offsets only: the window moves, not the screen
    return packs


class Painter:
    """Builds a stream the way a karaoke encoder does: it tracks the screen with a Model and
    writes each tile with one Tile Block for its two commonest colours plus a Tile Block XOR for
    every further colour, and colour wipes with Tile Block XOR alone."""

    def __init__(self, packs):
        self.model, self.packs = Model(), []
        for p in packs:
            self.emit(p)

    def emit(self, p):
        self.packs.append(p)
        self.model.pack(p)

    def tile_at(self, row, col):
        return [self.model.rows[row * 12 + r][col * 6:col * 6 + 6] for r in range(12)]

    def paint(self, row, col, want):
        if want == self.tile_at(row, col):
            return
        flat = [v for line in want for v in line]
        order = sorted(set(flat), key=lambda v: (-flat.count(v), v))
        c0, c1 = order[0], order[1] if len(order) > 1 else order[0]
        bits = lambda pick: [sum(32 >> c for c in range(6) if pick(want[r][c])) for r in range(12)]
        self.emit(tile(TILE, c0, c1, row, col, bits(lambda v: v == c1)))
        for v in order[2:]:
            self.emit(tile(XOR, 0, c0 ^ v, row, col, bits(lambda u: u == v)))

    def xor_to(self, row, col, want):
        have = self.tile_at(row, col)
        diff = sorted({have[r][c] ^ want[r][c] for r in range(12) for c in range(6)} - {0})
        for x in diff:
            self.emit(tile(XOR, 0, x, row, col,
                           [sum(32 >> c for c in range(6) if have[r][c] ^ want[r][c] == x)
                            for r in range(12)]))


def big_text(text):
    """Pixels of `text` in the 5 x 7 font doubled to 10 x 14, 12 pixels per letter, set inside a
    24-pixel band two tiles high: {(x, y)} relative to the band's top-left."""
    fill = set()
    for i, letter in enumerate(text):
        if letter == " ":
            continue
        for r, bits in enumerate(FONT[letter].split()):
            for c, b in enumerate(bits):
                if b == "#":
                    fill |= {(12 * i + 1 + 2 * c + dx, 5 + 2 * r + dy) for dx in (0, 1) for dy in (0, 1)}
    return fill


def outline(fill):
    ring = {(x + dx, y + dy) for x, y in fill for dx in (-1, 0, 1) for dy in (-1, 0, 1)}
    return ring - fill


def karaoke(painter, background, lines, fills, outline_colour, sung, wipes):
    """Draws each (row, col, text) of `lines` with a 1-pixel outline over `background(x, y)`
    (screen coordinates), then wipes line k from the left to `wipes[k]` pixels into `sung`."""
    drawn = []
    for (row, col, text), fill_colour in zip(lines, fills):
        x0, y0 = col * 6, row * 12
        fill = {(x0 + x, y0 + y) for x, y in big_text(text)}
        edge = outline(fill)
        cols = range((min(x for x, _ in edge)) // 6, max(x for x, _ in edge) // 6 + 1)
        for r in (row, row + 1):
            for c in cols:
                want = [[fill_colour if (c * 6 + x, r * 12 + y) in fill else
                         outline_colour if (c * 6 + x, r * 12 + y) in edge else
                         background(c * 6 + x, r * 12 + y) for x in range(6)] for y in range(12)]
                painter.paint(r, c, want)
        drawn.append((row, x0, fill))
    for (row, x0, fill), width in zip(drawn, wipes):
        for step in range(0, width, 3):
            hi = x0 + step + 3
            col = (hi - 1) // 6
            for r in (row, row + 1):
                have = painter.tile_at(r, col)
                want = [[sung if (col * 6 + x, r * 12 + y) in fill and col * 6 + x < hi else have[y][x]
                         for x in range(6)] for y in range(12)]
                painter.xor_to(r, col, want)


# Realistic karaoke screens, the kinds a downloaded MP3+G carries.
KARAOKE_BLUE = [colours(LOW, [0x000, 0x00B, 0xFFF, 0xF4F, 0xFF0, 0x000, 0x000, 0x000]),
                colours(HIGH, [0x000] * 8)]


def stream_karaoke_blue():
    """Memory Preset blue (colour 1), white lyrics (2) with a black outline (0) and a pink colour
    wipe (3): the first line sung, the second half sung. The transparent-colour table is never
    loaded, as on most discs, so only the preset or an index key shows the visual."""
    painter = Painter(KARAOKE_BLUE + [pk(MEMORY, [1, 0]), pk(BORDER, [1])])
    lines = [(4, 4, "SING ALONG"), (8, 4, "LOVE IS ALL"), (12, 4, "YOU NEED")]
    karaoke(painter, lambda x, y: 1, lines, [2, 2, 4], 0, 3, [120, 66])
    return painter.packs


KARAOKE_TILES = [colours(LOW, [0x000, 0x026, 0x04A, 0xFFF, 0xFC0, 0x000, 0x000, 0x000]),
                 colours(HIGH, [0x000] * 8)]


def tiles_background(x, y):
    """Two shades of blue painted with tiles: dark (1) above tile row 6, light (2) from row 12,
    and a checker dither of both between."""
    band = y // 12
    if band < 6:
        return 1
    if band >= 12:
        return 2
    return 1 + (x + y) % 2


def stream_karaoke_tiles():
    """The background painted tile by tile in two shades of blue (1, 2) after a Memory Preset of
    black (0), the colour of the lyric outline, so the preset key keys the outline and not the
    background. White lyrics (3), an amber wipe (4), then a scroll moves the window by (2, 5)."""
    painter = Painter(KARAOKE_TILES + [pk(MEMORY, [0, 0]), pk(BORDER, [1])])
    for row in range(18):
        for col in range(50):
            painter.paint(row, col, [[tiles_background(col * 6 + x, row * 12 + y) for x in range(6)]
                                     for y in range(12)])
    lines = [(3, 5, "KARAOKE"), (8, 3, "GO SING IT"), (13, 6, "TILED BLUE")]
    karaoke(painter, tiles_background, lines, [3, 3, 3], 0, 4, [84, 45])
    painter.emit(scroll(SPRESET, 0, 0, 2, 0, 5))
    return painter.packs


SMALL = {"presets": stream_presets, "tiles": stream_tiles, "xor": stream_xor,
         "scroll": stream_scroll, "palette": stream_palette, "ignored": stream_ignored,
         "lyrics": stream_lyrics}
# Realistic streams: sampled less densely, with mask keys (the background's colours, and one
# derived from the position) and per-index counts. NAME: (build, background mask).
KARAOKE = {"karaoke-blue": (stream_karaoke_blue, 0x0002),
           "karaoke-tiles": (stream_karaoke_tiles, 0x0006)}
KARAOKE_STEP, KARAOKE_RGBA = 8, 64
MIXED_SEED, MIXED_PACKS, MIXED_STEP = 0x5EED0001, 3000, 25
LONG_SEED, LONG_PACKS, LONG_STEP = 0x5EED0300, 90000, 997


def keys_for(applied):
    return ["none", "table", "preset", "index:%d" % (applied % 16)]


def expect(stream, step, rgba_every, header, background=None):
    model, lines, count = Model(), list(header), len(stream) // 24
    samples = set(range(0, count + 1, step)) | {count}
    if 0 in samples:
        lines.append(model.state_line(0))
    for i in range(count):
        model.pack(stream[24 * i:24 * i + 24])
        applied = i + 1
        if applied in samples:
            lines.append(model.state_line(applied))
            if applied % rgba_every == 0 or applied == count:
                keys = keys_for(applied)
                if background is not None:
                    keys += ["mask:%04x" % background, "mask:%04x" % (applied * 40503 & 0xFFFF)]
                lines += [model.rgba_line(applied, k) for k in keys]
                if background is not None:
                    lines += [model.counts_line(applied, r) for r in ("window", "edge")]
    return "\n".join(lines) + "\n"


def generate(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    head = "# cdg-vectors: tools/cdg-vectors.py (independent model of conformance/cdg/README.md)"
    for name, build in SMALL.items():
        stream = b"".join(build())
        with open(os.path.join(out_dir, name + ".cdg"), "wb") as f:
            f.write(stream)
        text = expect(stream, 1, 4, [head, "# stream %s.cdg, %d packs" % (name, len(stream) // 24)])
        with open(os.path.join(out_dir, name + ".expect"), "w") as f:
            f.write(text)
        print("%-8s %4d packs" % (name, len(stream) // 24))
    for name, (build, background) in KARAOKE.items():
        stream = b"".join(build())
        with open(os.path.join(out_dir, name + ".cdg"), "wb") as f:
            f.write(stream)
        text = expect(stream, KARAOKE_STEP, KARAOKE_RGBA,
                      [head, "# stream %s.cdg, %d packs, background mask %04x"
                       % (name, len(stream) // 24, background)], background)
        with open(os.path.join(out_dir, name + ".expect"), "w") as f:
            f.write(text)
        print("%-13s %4d packs" % (name, len(stream) // 24))
    mixed = lcg_stream(MIXED_SEED, MIXED_PACKS)
    with open(os.path.join(out_dir, "mixed.cdg"), "wb") as f:
        f.write(mixed)
    with open(os.path.join(out_dir, "mixed.expect"), "w") as f:
        f.write(expect(mixed, MIXED_STEP, MIXED_STEP * 8,
                       [head, "# stream mixed.cdg = lcg %#x x %d packs" % (MIXED_SEED, MIXED_PACKS)]))
    print("mixed    %4d packs" % MIXED_PACKS)
    long = lcg_stream(LONG_SEED, LONG_PACKS)
    with open(os.path.join(out_dir, "long-5min.expect"), "w") as f:
        f.write(expect(long, LONG_STEP, LONG_STEP * 9,
                       [head, "# stream lcg %#x x %d packs (5 minutes; not committed)"
                        % (LONG_SEED, LONG_PACKS)]))
    print("long-5min %d packs (generated only)" % LONG_PACKS)


def check():
    generated = lambda d: [n for n in os.listdir(d) if n.endswith((".cdg", ".expect"))]
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
        sys.exit("conformance/cdg/ differs from tools/cdg-vectors.py; regenerate it\n" +
                 "\n".join("%s: %s" % (k, ", ".join(v)) for k, v in problems))
    print("conformance/cdg/: %d files match the generator" % len(wanted))


def window(name, key):
    build = SMALL[name] if name in SMALL else KARAOKE[name][0]
    model, stream = Model(), b"".join(build())
    for i in range(0, len(stream), 24):
        model.pack(stream[i:i + 24])
    sys.stdout.buffer.write(model.window(key))


def main():
    if sys.argv[1:] == ["--check"]:
        check()
    elif len(sys.argv) == 4 and sys.argv[1] == "--window" and (sys.argv[2] in SMALL
                                                              or sys.argv[2] in KARAOKE):
        window(sys.argv[2], sys.argv[3])
    elif sys.argv[1:]:
        sys.exit("usage: python3 -I tools/cdg-vectors.py [--check | --window NAME KEY]")
    else:
        generate(OUT_DIR)


if __name__ == "__main__":
    main()
