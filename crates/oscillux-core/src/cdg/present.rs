// SPDX-License-Identifier: AGPL-3.0-only
//! CD+G presentation: draws a decoded screen as a modern, full-frame picture.
//!
//! [`Presenter`] turns the decoder state into an opaque RGBA8 frame of any size:
//!
//! - The background colour index comes from the window's edge ring ([`background_index`]).
//! - The stage fills the frame in that colour as a vertical gradient, lighter at the top and
//!   darker at the bottom, with ordered dither. When the colour changes the stage eases to the
//!   new colour over [`EASE_MS`] of media time; the first frame and a backwards seek snap.
//! - The 288 x 192 window is doubled with Scale2x (EPX) on the colour indices, then drawn as
//!   smooth vector-like shapes into a centred 3:2 rectangle of the frame height (or width, for
//!   frames narrower than 3:2). Each colour present is a layer, ordered by its distance from the
//!   background colour; a layer's coverage mask (that colour or any farther one) is box blurred
//!   and cut at [`EDGE_THRESHOLD`] with a ramp about one frame pixel wide, which rounds corners
//!   and turns pixel stair-steps into anti-aliased lines. Background-index pixels are
//!   transparent, so the stage shows through and there is no border or pillarbox.
//! - A box-blurred mask of the other pixels is drawn under the graphics as a translucent black
//!   shadow, offset one window pixel down and right.
//!
//! All buffers are allocated in [`Presenter::new`]; [`Presenter::present`] never allocates,
//! locks or does I/O. Everything is integer arithmetic, so every target draws the same bytes.

use alloc::vec;
use alloc::vec::Vec;

use super::{
    Decoder, Region, EDGE_PIXELS, SCREEN_WIDTH, TILE_HEIGHT, TILE_WIDTH, WINDOW_HEIGHT,
    WINDOW_WIDTH,
};

/// Largest accepted frame width or height.
pub const MAX_DIMENSION: usize = 8192;
/// Media time the stage takes to ease to a new background colour.
pub const EASE_MS: i64 = 300;
/// Shadow opacity where the blurred mask is full, out of 255.
pub const SHADOW_ALPHA: u32 = 166;
/// Squared colour distance (4-bit levels) from the background at which a colour casts a shadow.
pub const INK_DISTANCE: i32 = 12;
/// Brightness of the backdrop's base relative to the background colour, out of 1024.
pub const BASE_LEVEL: i64 = 230;
/// Drift periods of the two glows' centres (x, y), in media milliseconds.
pub const GLOW_PERIODS_MS: [[i64; 2]; 2] = [[23_000, 31_000], [27_000, 37_000]];
/// Level (of 255) of a blurred layer mask where its edge is drawn. Below the 127.5 of a straight
/// edge, so a lone window pixel (113 after the blur) still draws.
pub const EDGE_THRESHOLD: i64 = 100;

const X2_WIDTH: usize = WINDOW_WIDTH * 2;
const X2_HEIGHT: usize = WINDOW_HEIGHT * 2;
const X2_SIZE: usize = X2_WIDTH * X2_HEIGHT;
/// At most every index but the background is a layer.
const MAX_LAYERS: usize = 15;
/// Zero padding around the shadow mask, wider than the blur so the blur never reaches its edge.
const PAD: usize = 4;
const MASK_WIDTH: usize = WINDOW_WIDTH + 2 * PAD;
const MASK_HEIGHT: usize = WINDOW_HEIGHT + 2 * PAD;
/// Shadow offset, one window pixel in 16.16 fixed point.
const SHADOW_OFFSET: i64 = 1 << 16;
/// Backdrop sample spacing in frame pixels; the glows and vignette are interpolated between.
const BACKDROP_STEP: usize = 8;
const BAYER: [[u32; 4]; 4] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]];

/// The background colour index of the current window: the Memory Preset colour when it covers at
/// least half of the edge ring, otherwise the most common ring index (ties to the lowest index).
pub fn background_index(decoder: &Decoder) -> u8 {
    let mut counts = [0u32; 16];
    decoder.index_counts(Region::Edge, &mut counts);
    let preset = decoder.state().preset & 0x0F;
    if counts[preset as usize] as usize * 2 >= EDGE_PIXELS {
        return preset;
    }
    let mut best = 0usize;
    for (i, &count) in counts.iter().enumerate() {
        if count > counts[best] {
            best = i;
        }
    }
    best as u8
}

/// The indices that belong to the backdrop: the background index and every index covering at
/// least a quarter of the edge ring, so a painted background of several shades is not drawn as
/// graphics and casts no shadow.
pub fn backdrop_indices(decoder: &Decoder) -> [bool; 16] {
    let mut counts = [0u32; 16];
    decoder.index_counts(Region::Edge, &mut counts);
    let mut set = counts.map(|count| count as usize * 4 >= EDGE_PIXELS);
    set[background_index(decoder) as usize] = true;
    set
}

/// One axis sample: the two source cells, the weight (0..=255, of 256) of the second, and the
/// edge feather (0..=256, of 256; 0 outside the rectangle).
#[derive(Clone, Copy, Default)]
struct Tap {
    i0: u32,
    i1: u32,
    f: u32,
    edge: u32,
}

/// Bilinear taps for `len` destination cells starting at `origin`, mapping the rectangle
/// `[start, start + span)` onto `size` source cells; `shift` (16.16) moves the source sample.
/// Positions clamp to the source. `edge` ramps from 0 outside the rectangle to 256 over
/// `feather` cells inside each end (256 throughout when `feather` is 0).
fn taps(out: &mut [Tap], start: usize, span: usize, size: usize, shift: i64, feather: usize) {
    let max = ((size - 1) as i64) << 16;
    for (x, tap) in out.iter_mut().enumerate() {
        let d = x as i64 - start as i64;
        let pos = ((2 * d + 1) * size as i64 * 65536).div_euclid(2 * span as i64) - 32768 + shift;
        let pos = pos.clamp(0, max);
        let i0 = (pos >> 16) as u32;
        *tap = Tap {
            i0,
            i1: (i0 + 1).min(size as u32 - 1),
            f: ((pos & 0xFFFF) >> 8) as u32,
            edge: if d < 0 || d as usize >= span {
                0
            } else {
                let e = (d as usize).min(span - 1 - d as usize);
                ((2 * e + 1) * 128)
                    .checked_div(feather)
                    .map_or(256, |v| v.min(256)) as u32
            },
        };
    }
}

/// Scale2x (EPX) with ink priority: doubles `src` (`w` x `h` colour indices) into `dst`
/// (`2w` x `2h`). Corners round as in EPX, except where two diagonals cross (the diagonal
/// neighbour has the pixel's own colour, a 2 x 2 checker): there the corner takes the
/// neighbours' colour only when it ranks above the pixel's own. Diagonal ink steps then join
/// instead of both diagonals cutting each other into an X.
fn scale2x(src: &[u8], w: usize, h: usize, rank: &[u16; 16], dst: &mut [u8]) {
    let dw = 2 * w;
    for y in 0..h {
        let up = if y == 0 { 0 } else { y - 1 };
        let down = if y + 1 == h { y } else { y + 1 };
        for x in 0..w {
            let left = if x == 0 { 0 } else { x - 1 };
            let right = if x + 1 == w { x } else { x + 1 };
            let p = src[y * w + x];
            let a = src[up * w + x];
            let b = src[y * w + right];
            let c = src[y * w + left];
            let d = src[down * w + x];
            let at = 2 * y * dw + 2 * x;
            let take = |q: u8, diagonal: u8| diagonal != p || rank[q as usize] > rank[p as usize];
            let ul = src[up * w + left];
            let ur = src[up * w + right];
            let dl = src[down * w + left];
            let dr = src[down * w + right];
            dst[at] = if c == a && c != d && a != b && take(a, ul) {
                a
            } else {
                p
            };
            dst[at + 1] = if a == b && a != c && b != d && take(b, ur) {
                b
            } else {
                p
            };
            dst[at + dw] = if d == c && d != b && c != a && take(c, dl) {
                c
            } else {
                p
            };
            dst[at + dw + 1] = if b == d && b != a && d != c && take(d, dr) {
                d
            } else {
                p
            };
        }
    }
}

/// `round(x / 255)` for `x <= 65535`.
fn div255(x: u32) -> u32 {
    (x + 128 + ((x + 128) >> 8)) >> 8
}

/// A 12-bit `0xRGB` colour as 8.8 fixed-point channels (`c * 17 << 8`).
fn colour_8_8(rgb: u16) -> [i64; 3] {
    [
        (((rgb >> 8) & 0xF) as i64 * 17) << 8,
        (((rgb >> 4) & 0xF) as i64 * 17) << 8,
        ((rgb & 0xF) as i64 * 17) << 8,
    ]
}

/// Magnification rank of each index: its squared colour distance (4-bit levels) from the
/// background colour times 16, plus the index to break ties; the background ranks 0.
fn ranks(background: u8, palette: &[u16; 16]) -> [u16; 16] {
    let bg = palette[background as usize];
    let mut rank = [0u16; 16];
    for (i, entry) in rank.iter_mut().enumerate() {
        if i as u8 == background {
            continue;
        }
        let mut distance = 0u16;
        for shift in [8, 4, 0] {
            let d = ((palette[i] >> shift) & 0xF) as i16 - ((bg >> shift) & 0xF) as i16;
            distance += (d * d) as u16;
        }
        *entry = distance * 16 + i as u16 + 1;
    }
    rank
}

/// Draws decoder states as full-frame RGBA8 pictures of one size.
pub struct Presenter {
    width: usize,
    height: usize,
    window: Vec<u8>,
    x2: Vec<u8>,
    /// Blurred coverage mask of each layer, `X2_SIZE` bytes each, lowest rank first.
    layers: Vec<u8>,
    layer_scratch: Vec<u16>,
    layer_index: [u8; MAX_LAYERS],
    layer_count: usize,
    /// Edge ramp steepness: coverage gained per mask level, 8.8 fixed point.
    ramp: i64,
    mask: Vec<u8>,
    blur: Vec<u16>,
    cols: Vec<Tap>,
    rows: Vec<Tap>,
    shadow_cols: Vec<Tap>,
    shadow_rows: Vec<Tap>,
    stage_row: Vec<[u32; 3]>,
    /// Per frame pixel, the graphics over the shadow, rebuilt only when the window, background
    /// or palette changes: premultiplied R, G and B, `255 - alpha`, and the shadow's `keep`.
    overlay: Vec<[u8; 5]>,
    frame: Vec<u8>,
    /// The background and palette the shadow mask was built for; `None` before the first frame.
    built: Option<(u8, [u16; 16])>,
    /// The inputs of the frame in `frame`: background, palette, stage colour.
    drawn: Option<(u8, [u16; 16], [i64; 3], i64)>,
    last_ms: Option<i64>,
    from: [i64; 3],
    to: [i64; 3],
    stage: [i64; 3],
    ease_start: i64,
}

impl Presenter {
    /// A presenter for `width` x `height` frames (each 1..=[`MAX_DIMENSION`]), or `None` when a
    /// dimension is out of range. Allocates every buffer `present` uses.
    pub fn new(width: usize, height: usize) -> Option<Self> {
        if !(1..=MAX_DIMENSION).contains(&width) || !(1..=MAX_DIMENSION).contains(&height) {
            return None;
        }
        // The window's 3:2 rectangle at full height, or at full width when the frame is narrower.
        let (rx, ry, rw, rh) = if width * 2 >= height * 3 {
            let rw = (height * 3).div_ceil(2);
            ((width - rw) / 2, 0, rw, height)
        } else {
            let rh = (width * 2 / 3).max(1);
            (0, (height - rh) / 2, width, rh)
        };
        let mut presenter = Presenter {
            width,
            height,
            window: vec![0; WINDOW_WIDTH * WINDOW_HEIGHT],
            x2: vec![0; X2_WIDTH * X2_HEIGHT],
            layers: vec![0; X2_SIZE * MAX_LAYERS],
            layer_scratch: vec![0; X2_SIZE],
            layer_index: [0; MAX_LAYERS],
            layer_count: 0,
            // A blurred straight edge climbs 85 levels per mask pixel and a mask pixel spans
            // `rw / 576` frame pixels; ramp the full 255 over about 1.25 frame pixels.
            ramp: (rw as i64 * 256 / 300).max(256),
            mask: vec![0; MASK_WIDTH * MASK_HEIGHT],
            blur: vec![0; MASK_WIDTH * MASK_HEIGHT],
            cols: vec![Tap::default(); width],
            rows: vec![Tap::default(); height],
            shadow_cols: vec![Tap::default(); width],
            shadow_rows: vec![Tap::default(); height],
            stage_row: vec![[0; 3]; width],
            overlay: vec![[0, 0, 0, 255, 255]; width * height],
            frame: vec![255; width * height * 4],
            built: None,
            drawn: None,
            last_ms: None,
            from: [0; 3],
            to: [0; 3],
            stage: [0; 3],
            ease_start: 0,
        };
        let shift = ((PAD as i64) << 16) - SHADOW_OFFSET;
        // Feather the rectangle over one tile, so a painted window edge fades into the stage.
        taps(
            &mut presenter.cols,
            rx,
            rw,
            X2_WIDTH,
            0,
            rw * TILE_WIDTH / WINDOW_WIDTH,
        );
        taps(
            &mut presenter.rows,
            ry,
            rh,
            X2_HEIGHT,
            0,
            rh * TILE_HEIGHT / WINDOW_HEIGHT,
        );
        // The shadow samples the padded mask, so cells outside the rectangle read its zero ring.
        taps(&mut presenter.shadow_cols, rx, rw, WINDOW_WIDTH, shift, 0);
        taps(&mut presenter.shadow_rows, ry, rh, WINDOW_HEIGHT, shift, 0);
        // Outside the rectangle the shadow reads the mask's zero corner instead of a clamped
        // window edge.
        for (taps, size) in [
            (&mut presenter.shadow_cols, MASK_WIDTH),
            (&mut presenter.shadow_rows, MASK_HEIGHT),
        ] {
            for tap in taps.iter_mut() {
                tap.i1 = (tap.i0 + 1).min(size as u32 - 1);
                if tap.edge == 0 {
                    *tap = Tap::default();
                }
            }
        }
        Some(presenter)
    }

    /// Frame width in pixels.
    pub fn width(&self) -> usize {
        self.width
    }

    /// Frame height in pixels.
    pub fn height(&self) -> usize {
        self.height
    }

    /// The stage colour of the last frame as 8.8 fixed-point RGB.
    pub fn stage_colour(&self) -> [i64; 3] {
        self.stage
    }

    /// Draws the decoder's current state at media time `millis` and returns the opaque RGBA8
    /// frame, rows top to bottom. `millis` only drives the stage easing; the caller advances the
    /// decoder. Never allocates.
    pub fn present(&mut self, decoder: &Decoder, millis: i64) -> &[u8] {
        let state = decoder.state();
        let background = background_index(decoder);
        let palette = state.palette;
        self.ease(colour_8_8(palette[background as usize]), millis);

        let (x0, y0) = state.window_origin();
        let mut window_changed = false;
        for row in 0..WINDOW_HEIGHT {
            let at = (y0 + row) * SCREEN_WIDTH + x0;
            let src = &state.screen[at..at + WINDOW_WIDTH];
            let dst = &mut self.window[row * WINDOW_WIDTH..(row + 1) * WINDOW_WIDTH];
            if dst != src {
                dst.copy_from_slice(src);
                window_changed = true;
            }
        }
        let rebuilt = window_changed || self.built != Some((background, palette));
        if rebuilt {
            let backdrop = backdrop_indices(decoder);
            let rank = ranks(background, &palette);
            scale2x(
                &self.window,
                WINDOW_WIDTH,
                WINDOW_HEIGHT,
                &rank,
                &mut self.x2,
            );
            self.build_layers(&backdrop, &rank);
            self.build_mask(&backdrop, &rank);
            self.compose(background, &palette);
            self.built = Some((background, palette));
        }
        let inputs = (background, palette, self.stage, millis);
        if !rebuilt && self.drawn == Some(inputs) {
            return &self.frame;
        }
        self.draw(millis);
        self.drawn = Some(inputs);
        &self.frame
    }

    fn ease(&mut self, target: [i64; 3], millis: i64) {
        match self.last_ms {
            Some(last) if millis >= last => {
                if target != self.to {
                    self.from = self.stage;
                    self.to = target;
                    self.ease_start = millis;
                }
            }
            _ => {
                self.from = target;
                self.to = target;
                self.ease_start = millis;
            }
        }
        self.last_ms = Some(millis);
        let t = (millis - self.ease_start).clamp(0, EASE_MS);
        for c in 0..3 {
            self.stage[c] = self.from[c] + (self.to[c] - self.from[c]) * t / EASE_MS;
        }
    }

    /// One layer per non-background index present in the doubled window, lowest rank first. A
    /// layer's mask is 255 where the pixel ranks at or above the layer's index, box blurred once
    /// (radius 1, separable, edges clamped).
    fn build_layers(&mut self, backdrop: &[bool; 16], rank: &[u16; 16]) {
        let mut present = [false; 16];
        for &index in self.x2.iter() {
            present[index as usize] = !backdrop[index as usize];
        }
        self.layer_count = 0;
        for (i, _) in present.iter().enumerate().filter(|(_, &p)| p) {
            self.layer_index[self.layer_count] = i as u8;
            self.layer_count += 1;
        }
        self.layer_index[..self.layer_count].sort_unstable_by_key(|&i| rank[i as usize]);
        for layer in 0..self.layer_count {
            let floor = rank[self.layer_index[layer] as usize];
            let mask = &mut self.layers[layer * X2_SIZE..(layer + 1) * X2_SIZE];
            for (m, &index) in mask.iter_mut().zip(self.x2.iter()) {
                *m = if rank[index as usize] >= floor {
                    255
                } else {
                    0
                };
            }
            for y in 0..X2_HEIGHT {
                let row = &mask[y * X2_WIDTH..(y + 1) * X2_WIDTH];
                let out = &mut self.layer_scratch[y * X2_WIDTH..(y + 1) * X2_WIDTH];
                for x in 0..X2_WIDTH {
                    let l = row[x.saturating_sub(1)] as u16;
                    let r = row[(x + 1).min(X2_WIDTH - 1)] as u16;
                    out[x] = l + row[x] as u16 + r;
                }
            }
            for y in 0..X2_HEIGHT {
                let up = y.saturating_sub(1) * X2_WIDTH;
                let down = (y + 1).min(X2_HEIGHT - 1) * X2_WIDTH;
                for x in 0..X2_WIDTH {
                    let sum = self.layer_scratch[up + x] as u32
                        + self.layer_scratch[y * X2_WIDTH + x] as u32
                        + self.layer_scratch[down + x] as u32;
                    mask[y * X2_WIDTH + x] = ((sum + 4) / 9) as u8;
                }
            }
        }
    }

    /// Marks ink pixels 255 in the padded mask and box blurs it twice (radius 1, separable).
    /// Ink is any index outside the backdrop whose colour is at least [`INK_DISTANCE`]
    /// (squared, in 4-bit levels) from the background colour.
    fn build_mask(&mut self, backdrop: &[bool; 16], rank: &[u16; 16]) {
        let mut ink = [false; 16];
        for (i, flag) in ink.iter_mut().enumerate() {
            *flag = !backdrop[i] && (rank[i] >> 4) as i32 >= INK_DISTANCE;
        }
        self.mask.fill(0);
        for y in 0..WINDOW_HEIGHT {
            let src = &self.window[y * WINDOW_WIDTH..(y + 1) * WINDOW_WIDTH];
            let at = (y + PAD) * MASK_WIDTH + PAD;
            for (m, &index) in self.mask[at..at + WINDOW_WIDTH].iter_mut().zip(src) {
                *m = if ink[index as usize] { 255 } else { 0 };
            }
        }
        for _ in 0..2 {
            for y in 0..MASK_HEIGHT {
                let row = &self.mask[y * MASK_WIDTH..(y + 1) * MASK_WIDTH];
                let out = &mut self.blur[y * MASK_WIDTH..(y + 1) * MASK_WIDTH];
                out[0] = 0;
                out[MASK_WIDTH - 1] = 0;
                for x in 1..MASK_WIDTH - 1 {
                    out[x] = row[x - 1] as u16 + row[x] as u16 + row[x + 1] as u16;
                }
            }
            self.mask[..MASK_WIDTH].fill(0);
            self.mask[(MASK_HEIGHT - 1) * MASK_WIDTH..].fill(0);
            for y in 1..MASK_HEIGHT - 1 {
                for x in 0..MASK_WIDTH {
                    let sum = self.blur[(y - 1) * MASK_WIDTH + x] as u32
                        + self.blur[y * MASK_WIDTH + x] as u32
                        + self.blur[(y + 1) * MASK_WIDTH + x] as u32;
                    self.mask[y * MASK_WIDTH + x] = ((sum + 4) / 9) as u8;
                }
            }
        }
    }

    /// Composes the graphics layers and the shadow into `overlay`.
    fn compose(&mut self, background: u8, palette: &[u16; 16]) {
        // Premultiplied colour of each index; the background index is transparent.
        let mut lut = [[0u32; 4]; 16];
        for (i, entry) in lut.iter_mut().enumerate() {
            if i as u8 != background {
                let rgb = palette[i] as u32;
                *entry = [
                    ((rgb >> 8) & 0xF) * 17,
                    ((rgb >> 4) & 0xF) * 17,
                    (rgb & 0xF) * 17,
                    255,
                ];
            }
        }
        let width = self.width;
        for (y, line) in self.overlay.chunks_exact_mut(width).enumerate() {
            let ry = self.rows[y];
            let sy = self.shadow_rows[y];
            let row0 = ry.i0 as usize * X2_WIDTH;
            let row1 = ry.i1 as usize * X2_WIDTH;
            let m0 = &self.mask[sy.i0 as usize * MASK_WIDTH..][..MASK_WIDTH];
            let m1 = &self.mask[sy.i1 as usize * MASK_WIDTH..][..MASK_WIDTH];
            for (x, px) in line.iter_mut().enumerate() {
                let sx = self.shadow_cols[x];
                let top =
                    m0[sx.i0 as usize] as u32 * (256 - sx.f) + m0[sx.i1 as usize] as u32 * sx.f;
                let bottom =
                    m1[sx.i0 as usize] as u32 * (256 - sx.f) + m1[sx.i1 as usize] as u32 * sx.f;
                let m = (top * (256 - sy.f) + bottom * sy.f) >> 16;
                let keep = 255 - div255(m * SHADOW_ALPHA);
                let rx = self.cols[x];
                let mut g = [0u32; 4];
                let edge = rx.edge * ry.edge;
                if edge != 0 {
                    let w00 = (256 - rx.f) * (256 - ry.f);
                    let w01 = rx.f * (256 - ry.f);
                    let w10 = (256 - rx.f) * ry.f;
                    let w11 = rx.f * ry.f;
                    let (a, b) = (row0 + rx.i0 as usize, row0 + rx.i1 as usize);
                    let (c, d) = (row1 + rx.i0 as usize, row1 + rx.i1 as usize);
                    for layer in 0..self.layer_count {
                        let mask = &self.layers[layer * X2_SIZE..(layer + 1) * X2_SIZE];
                        let (m00, m01, m10, m11) = (mask[a], mask[b], mask[c], mask[d]);
                        if (m00 | m01 | m10 | m11) == 0 {
                            // Layers nest, so every later layer is empty here too.
                            break;
                        }
                        // Mask level in 8.8 fixed point.
                        let v = (m00 as u32 * w00
                            + m01 as u32 * w01
                            + m10 as u32 * w10
                            + m11 as u32 * w11)
                            >> 8;
                        let cov = (((v as i64 - EDGE_THRESHOLD * 256) * self.ramp) >> 16) + 128;
                        let cov = cov.clamp(0, 255) as u32;
                        if cov == 0 {
                            continue;
                        }
                        let p = &lut[self.layer_index[layer] as usize];
                        for ch in 0..4 {
                            g[ch] = div255(p[ch] * cov + g[ch] * (255 - cov));
                        }
                    }
                    for ch in g.iter_mut() {
                        *ch = (*ch * edge + 32768) >> 16;
                    }
                }
                *px = [
                    g[0] as u8,
                    g[1] as u8,
                    g[2] as u8,
                    (255 - g[3]) as u8,
                    keep as u8,
                ];
            }
        }
    }

    /// Draws the backdrop at `millis` under the overlay into `frame`.
    fn draw(&mut self, millis: i64) {
        let backdrop = Backdrop::new(self.stage, self.width as i64, self.height as i64, millis);
        let width = self.width;
        let rows = self.frame.chunks_exact_mut(width * 4);
        for (y, (line, over)) in rows.zip(self.overlay.chunks_exact(width)).enumerate() {
            backdrop.row(y as i64, &mut self.stage_row);
            let bayer = &BAYER[y & 3];
            for (x, (px, o)) in line.chunks_exact_mut(4).zip(over).enumerate() {
                let threshold = bayer[x & 3] * 16 + 8;
                let stage = self.stage_row[x];
                let (keep, clear) = (o[4] as u32, o[3] as u32);
                for c in 0..3 {
                    let s = ((stage[c] + threshold) >> 8).min(255);
                    let shade = div255(s * keep);
                    px[c] = (o[c] as u32 + div255(shade * clear)).min(255) as u8;
                }
                px[3] = 255;
            }
        }
    }
}

/// `0..=65536` and back over `period` ms, eased at both ends (smoothstep of a triangle wave).
fn drift(millis: i64, period: i64) -> i64 {
    let t = millis.rem_euclid(period);
    let tri = (2 * t * 65536 / period - 65536).abs();
    (((tri * tri) >> 16) * (3 * 65536 - 2 * tri)) >> 32
}

/// The stage behind the graphics: a dark base in the background colour, a light glow of that
/// colour and a glow of its hue-shifted neighbour drifting slowly, and a vignette. Colours are
/// 8.8 fixed point.
struct Backdrop {
    width: i64,
    height: i64,
    base: [i64; 3],
    glows: [([i64; 3], i64, i64, i64, i64); 2],
}

impl Backdrop {
    fn new(stage: [i64; 3], width: i64, height: i64, millis: i64) -> Self {
        let lighten = |v: i64, k: i64| v + (65280 - v) * k / 1024;
        let base = stage.map(|v| v * BASE_LEVEL / 1024 + (6 << 8));
        let warm = [0, 1, 2].map(|c| lighten((stage[c] + stage[(c + 2) % 3]) / 2, 80));
        let light = stage.map(|v| lighten(v, 180));
        let long = width.max(height);
        // (colour, centre x, centre y, 2^32 / radius^2, strength of 65536).
        let glow = |colour, n: usize, x: [i64; 2], y: [i64; 2], radius: i64, strength| {
            let [px, py] = GLOW_PERIODS_MS[n];
            let cx = width * (x[0] + (x[1] - x[0]) * drift(millis, px) / 65536) / 100;
            let cy = height * (y[0] + (y[1] - y[0]) * drift(millis + px / 3, py) / 65536) / 100;
            let r = (long * radius / 100).max(1);
            (colour, cx, cy, (1i64 << 32) / (r * r), strength)
        };
        Backdrop {
            width,
            height,
            base,
            glows: [
                glow(light, 0, [18, 34], [20, 40], 75, 36_000),
                glow(warm, 1, [66, 84], [60, 82], 65, 30_000),
            ],
        }
    }

    /// The stage colour of every pixel of row `y`.
    /// Row `y`, sampled every [`BACKDROP_STEP`] pixels and at the last pixel, linearly
    /// interpolated between samples (rounding half up).
    fn row(&self, y: i64, out: &mut [[u32; 3]]) {
        let last = out.len() - 1;
        let mut x0 = 0;
        out[0] = self.sample(0, y);
        while x0 < last {
            let x1 = (x0 + BACKDROP_STEP).min(last);
            out[x1] = self.sample(x1 as i64, y);
            let (a, b) = (out[x0], out[x1]);
            let span = (x1 - x0) as u32;
            for (k, px) in out[x0 + 1..x1].iter_mut().enumerate() {
                let t = k as u32 + 1;
                for ch in 0..3 {
                    px[ch] = (a[ch] * (span - t) + b[ch] * t + span / 2) / span;
                }
            }
            x0 = x1;
        }
    }

    fn sample(&self, x: i64, y: i64) -> [u32; 3] {
        let (hw, hh) = (self.width / 2, self.height / 2);
        let corner = (hw * hw + hh * hh).max(1);
        let mut c = self.base;
        for &(colour, cx, cy, inv, strength) in &self.glows {
            let d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy);
            let q = 65536 - ((d2 * inv) >> 16).min(65536);
            let a = (((q * q) >> 16) * strength) >> 16;
            for ch in 0..3 {
                c[ch] += ((colour[ch] - c[ch]) * a) >> 16;
            }
        }
        let v = 65536 - 30_000 * ((x - hw) * (x - hw) + (y - hh) * (y - hh)) / corner;
        c.map(|ch| ((ch * v) >> 16).clamp(0, 65280) as u32)
    }
}
