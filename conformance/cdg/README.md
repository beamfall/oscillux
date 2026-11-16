<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# CD+G decoder conformance

These vectors specify `oscillux_core::cdg` (C API `oscillux_cdg_*`). Every stream is synthetic:
hand-built packs for each instruction and edge case, and pseudo-random packs from the LCG below.
No commercial karaoke data is in this directory, and none may be added.

## Pack stream

A stream is a sequence of 24-byte packs at 300 packs per second; a trailing partial pack is
ignored. In each pack:

| Bytes | Meaning |
|---|---|
| 0 | command, masked with `0x3F`; only `0x09` (TV graphics) is decoded, all others are ignored |
| 1 | instruction, masked with `0x3F` |
| 2-3 | parity Q, never read |
| 4-19 | data symbols `d[0..16]`, each masked with `0x3F` |
| 20-23 | parity P, never read |

The screen is 300 x 216 colour indices (50 x 18 tiles of 6 x 12 pixels). The decoder state starts
with every index, colour, transparency, offset and preset colour at zero.

| Instruction | Effect |
|---|---|
| 1 Memory Preset | colour `d[0] & 0xF` fills the whole screen and becomes the preset colour. `d[1] & 0xF` is the repeat count; every repeat is applied again (idempotent unless something was drawn between repeats, which a repeat then clears) |
| 2 Border Preset | colour `d[0] & 0xF` fills every pixel outside x 6..294, y 12..204, and becomes the border colour |
| 6 Tile Block | colour0 `d[0] & 0xF`, colour1 `d[1] & 0xF`, row `d[2] & 0x1F`, column `d[3] & 0x3F`; rows above 17 or columns above 49 are ignored. Rows `d[4..16]` give 6 pixels each, bit 5 leftmost: a set bit writes colour1, a clear bit colour0, at x `column * 6`, y `row * 12` |
| 38 Tile Block XOR | as Tile Block, but each pixel becomes `old ^ colour` |
| 20 Scroll Preset, 24 Scroll Copy | colour `d[0] & 0xF`; horizontal command `(d[1] >> 4) & 3` (1 moves the screen 6 pixels right, 2 left, 0 and 3 not at all) and offset `min(d[1] & 7, 5)`; vertical command `(d[2] >> 4) & 3` (1 moves it 12 pixels down, 2 up) and offset `min(d[2] & 0xF, 11)`. The whole 300 x 216 screen moves; Scroll Copy wraps it around, Scroll Preset fills the vacated strip with the colour. The offsets replace the previous ones |
| 28 Define Transparent Colour | the transparent-colour table becomes `d[0..16]` (6 bits per colour index) |
| 30 / 31 Load Colour Table | entries 0..7 / 8..15: entry `i` is 12-bit `0xRGB` = `(d[2i] << 6) \| d[2i+1]` |
| any other | ignored |

The visible window is 288 x 192 pixels whose top-left screen pixel is `(6 + h_offset,
12 + v_offset)`.

## Transparency keys and RGBA

`window_rgba` writes the window as straight-alpha RGBA8, rows top to bottom, each 4-bit channel
`c` as `c * 17`. The host chooses the alpha with a key:

| Key | Alpha of colour index `i` |
|---|---|
| none | 255 |
| table | `round_half_up((63 - t[i]) * 255 / 63)`: 0 is opaque, 63 fully transparent |
| preset | 0 when `i` is the most recent Memory Preset colour, else 255 |
| index:k | 0 when `i == k`, else 255 |
| mask:MMMM | 0 when bit `i` of the 16-bit hex mask is set, else 255 (C `OSCILLUX_CDG_KEY_MASK`) |

The meaning of the transparent-colour table values (0 opaque, 63 transparent, linear between) is
this project's reading; the stream only carries the 6-bit values.

## Index counts

`index_counts` (C `oscillux_cdg_index_counts`) writes how many pixels of each colour index lie
in a region of the window: `window` is all 288 x 192 pixels, `edge` the 8928-pixel ring one tile
deep inside it (window x < 6 or x >= 282, or y < 12 or y >= 180). A host can derive a mask key
from the edge counts (the background of most karaoke screens); which rule it uses is host data
(`hosts/README.md`). Neither call allocates.

## Files

`tools/cdg-vectors.py` (standard-library Python, independent of the Rust decoder) writes every
file here; `python3 -I tools/cdg-vectors.py --check` (in `make gate`) regenerates them into a
temporary directory and fails on any difference.

- `NAME.cdg`: the stream. `presets`, `tiles`, `xor`, `scroll`, `palette` and `ignored` are
  hand-built for each instruction and edge (repeat counts, masked high bits, out-of-range tiles,
  every scroll command pair with wrap-around, palette reloads, ignored commands and
  instructions); `lyrics` is a synthetic lyric screen of block letters in bright, mid-grey and
  dark colours on a transparent colour 0, which `tools/shader/cdg-check.mjs` composites over
  every bundled visual; `karaoke-blue` and `karaoke-tiles` are realistic karaoke screens, built
  the way encoders build them (one Tile Block per tile for its two commonest colours, Tile Block
  XOR for the rest and for the colour wipe): `karaoke-blue` is a Memory Preset blue with white
  and yellow lyrics in a one-pixel black outline and a pink wipe, and no transparent-colour
  table; `karaoke-tiles` presets black (the outline colour), paints the background tile by tile
  in two blues with a dithered band, wipes in amber and ends on a Scroll Preset offset of (2, 5);
  `mixed` is `lcg(0x5EED0001)` x 3000 packs.
- `NAME.expect`: `state APPLIED SCREEN PALETTE TRANSPARENT H V PRESET BORDER` lines after
  `APPLIED` packs (SCREEN is the SHA-256 of the 64800 index bytes; PALETTE 16 x 3 hex digits;
  TRANSPARENT 16 x 2 hex digits) and `rgba APPLIED KEY SHA256` lines for the window. The
  karaoke streams also carry, at each rgba sample, two mask keys (the background's indices, and
  `(APPLIED * 40503) & 0xFFFF`) and `counts APPLIED window|edge C0,...,C15` lines.
- `long-5min.expect`: the same for `lcg(0x5EED0300)` x 90000 packs (5 minutes), which is not
  committed; the Rust tests generate it and reach each sample by seeking in shuffled order.

`crates/oscillux-core/tests/cdg_vectors.rs` decodes every stream sequentially and by seeking, on
the host and on wasm32 (`make test-wasi`), and must match every line exactly.

## LCG stream

`next()` advances a 64-bit state `s = s * 6364136223846793005 + 1442695040888963407 (mod 2^64)`
and returns `s >> 32`. For each pack: 24 bytes `next() & 0xFF`, then `sel = next() % 1000`:

| sel | Pack |
|---|---|
| < 500 | byte 0 low 6 bits = `next() & 0x3F` (0 when that is 9): an ignored command |
| < 800 | Tile Block |
| < 900 | Tile Block XOR |
| < 930 | Load Colour Table low |
| < 960 | Load Colour Table high |
| < 970 | Define Transparent Colour |
| < 980 | Scroll Copy |
| < 988 | Scroll Preset |
| < 993 | Memory Preset |
| < 997 | Border Preset |
| else | instruction `next() & 0x3F` (0 when it is one of the nine above) |

For every case but the first, byte 0 keeps its high two bits with low bits `0x09`, and byte 1
keeps its high two bits with the instruction in the low six.
