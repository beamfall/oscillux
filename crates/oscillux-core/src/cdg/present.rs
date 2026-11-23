// SPDX-License-Identifier: AGPL-3.0-only
//! CD+G presentation: draws a decoded screen as a modern, full-frame picture.
//!
//! [`Presenter`] turns the decoder state into an opaque RGBA8 frame of any size:
//!
//! - The background colour index comes from the window's edge ring ([`background_index`]). Every
//!   index covering a quarter of the ring belongs to the backdrop too ([`backdrop_indices`]), so
//!   painted backgrounds of several shades are not drawn as graphics.
//! - The stage colour eases to the background colour over [`EASE_MS`] of media time; the first
//!   frame and a backwards seek snap. The backdrop fills the frame from it: a deep base, a light
//!   glow and a hue-shifted glow drifting slowly with media time, and a vignette, with ordered
//!   dither.
//! - The 288 x 192 window is doubled with Scale2x (EPX) on the colour indices, then drawn as
//!   smooth vector-like shapes into a centred 3:2 rectangle of the frame height (or width, for
//!   frames narrower than 3:2). Each colour present is a layer, ordered by its distance from the
//!   background colour; a layer's coverage mask (that colour or any farther one) is blurred with
//!   a `[1, 4, 1]` kernel and cut at [`EDGE_THRESHOLD`] with a ramp a little over half a frame
//!   pixel wide, which rounds corners and turns pixel stair-steps into crisp anti-aliased lines
//!   of regular weight. A layer draws only where its own colour is under the blur, so it never
//!   fringes a farther colour's edges. Backdrop-index pixels are transparent, so the backdrop
//!   shows through and there is no border or pillarbox.
//! - A graphics colour that touches the backdrop and has less than [`MIN_CONTRAST_X10`] / 10
//!   contrast against its darkest or brightest point is mixed toward white or black until it
//!   does, unless it is outlined by a colour that is legible there.
//! - A box-blurred mask of the ink pixels is drawn under the graphics as a translucent black
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
pub const SHADOW_ALPHA: u32 = 110;
/// Squared colour distance (4-bit levels) from the background at which a colour casts a shadow.
pub const INK_DISTANCE: i32 = 12;
/// Brightness of the backdrop's base relative to the background colour, out of 1024.
pub const BASE_LEVEL: i64 = 230;
/// Drift periods of the two glows' centres (x, y), in media milliseconds.
pub const GLOW_PERIODS_MS: [[i64; 2]; 2] = [[23_000, 31_000], [27_000, 37_000]];
/// Centre weight of the layer blur kernel `[1, BLUR_CENTRE, 1]` (per axis).
pub const BLUR_CENTRE: u32 = 4;
/// Level (of 255) of a blurred layer mask where its edge is drawn. Just below the 177 a lone
/// window pixel reaches after the blur, so it still draws, and above the 127.5 of a straight
/// edge, so strokes are drawn at regular weight (each edge about 0.15 magnified pixels inside
/// the unblurred one) and letter counters stay open.
pub const EDGE_THRESHOLD: i64 = 171;
/// Least edge ramp: the smallest that still takes a full mask (255) to full coverage.
const MIN_RAMP: i64 = (127 * 256 + (255 - EDGE_THRESHOLD) - 1) / (255 - EDGE_THRESHOLD);
/// The steepest edge ramp, at the widest frame.
const MAX_RAMP: i64 = MAX_DIMENSION as i64 * 256 / 150;
const _: () = assert!(EDGE_THRESHOLD * 256 * MAX_RAMP <= i32::MAX as i64);
// A full mask (level 255 at every tap, 255 << 8 in 8.8) reaches full coverage at `MIN_RAMP`.
const _: () = assert!(((((255 << 8) - EDGE_THRESHOLD * 256) * MIN_RAMP) >> 16) + 128 >= 255);
/// Least contrast ratio, times 10, a graphics colour keeps against the whole backdrop.
pub const MIN_CONTRAST_X10: i64 = 35;

const X2_WIDTH: usize = WINDOW_WIDTH * 2;
const X2_HEIGHT: usize = WINDOW_HEIGHT * 2;
const X2_SIZE: usize = X2_WIDTH * X2_HEIGHT;
/// At most every index but the background is a layer.
const MAX_LAYERS: usize = 15;
/// Sum of the 2D layer blur kernel's weights.
const BLUR_AREA: u32 = (BLUR_CENTRE + 2) * (BLUR_CENTRE + 2);
// Layers live one per byte lane of a `u128`, and a lane holds counts up to `BLUR_AREA`; the
// horizontal pass multiplies by `BLUR_CENTRE` with a shift.
const _: () = assert!(MAX_LAYERS <= 16 && BLUR_AREA < 256 && BLUR_CENTRE.is_power_of_two());
/// The blurred mask byte of each lane's weighted neighbour count,
/// `round(255 * count / BLUR_AREA)`. With `BLUR_AREA` 36 that is
/// `7 * count + (count + 6) / 12`, and the second term counts the thresholds 6, 18 and 30 the
/// count reaches; no lane carries into the next (a count is at most 36, a level at most 255).
fn level(counts: u128) -> u128 {
    const _: () = assert!(BLUR_AREA == 36);
    let reached =
        |threshold: u8| ((counts + u128::from_ne_bytes([128 - threshold; 16])) & HIGH1) >> 7;
    counts * 7 + reached(6) + reached(18) + reached(30)
}

/// Nonzero in every byte lane that differs from the next lane up.
fn next_differs(lanes: u128) -> u128 {
    lanes ^ (lanes >> 8)
}

const LOW7: u128 = u128::from_ne_bytes([0x7f; 16]);
const HIGH1: u128 = u128::from_ne_bytes([0x80; 16]);

/// Bit `k` set for every nonzero byte lane `k` of `x`.
fn nonzero_lanes(x: u128) -> u32 {
    // The top bit of each nonzero lane, moved to the lane's low bit, then gathered eight lanes
    // at a time into the top byte by one multiply (the partial products never overlap).
    let lanes = ((((x & LOW7) + LOW7) | x) & HIGH1) >> 7;
    let gather = |half: u64| (half.wrapping_mul(0x0102_0408_1020_4080) >> 56) as u32;
    gather(lanes as u64) | gather((lanes >> 64) as u64) << 8
}
/// Zero padding around the shadow mask, wider than the blur so the blur never reaches its edge.
const PAD: usize = 4;
const MASK_WIDTH: usize = WINDOW_WIDTH + 2 * PAD;
const MASK_HEIGHT: usize = WINDOW_HEIGHT + 2 * PAD;
/// Words in a row of change bits: one bit per doubled pixel, and one per mask pixel.
const X2_WORDS: usize = X2_WIDTH.div_ceil(64);
const MASK_WORDS: usize = MASK_WIDTH.div_ceil(64);

/// Whether bit `x` of a row of change bits is set.
fn changed(bits: &[u64], x: u32) -> bool {
    bits[x as usize / 64] >> (x % 64) & 1 != 0
}
/// Shadow offset, one window pixel in 16.16 fixed point.
const SHADOW_OFFSET: i64 = 1 << 16;
/// Backdrop sample spacing in frame pixels; the glows and vignette are interpolated between.
const BACKDROP_STEP: usize = 8;
const STEP_SHIFT: u32 = BACKDROP_STEP.trailing_zeros();
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
/// Positions clamp to `last`, the highest index the source can be read at.
fn taps(
    out: &mut [Tap],
    (start, span): (usize, usize),
    size: usize,
    last: usize,
    shift: i64,
    feather: usize,
) {
    let max = (last as i64) << 16;
    for (x, tap) in out.iter_mut().enumerate() {
        let d = x as i64 - start as i64;
        let pos = ((2 * d + 1) * size as i64 * 65536).div_euclid(2 * span as i64) - 32768 + shift;
        let pos = pos.clamp(0, max);
        let i0 = (pos >> 16) as u32;
        *tap = Tap {
            i0,
            i1: (i0 + 1).min(last as u32),
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
/// instead of both diagonals cutting each other into an X. Only the source columns
/// `spans[y].0..spans[y].1` of each row `y` are doubled; the rest of `dst` is left as it was.
fn scale2x(src: &[u8], w: usize, h: usize, rank: &[u16; 16], spans: &[Span], dst: &mut [u8]) {
    let dw = 2 * w;
    for (y, &(lo, hi)) in spans.iter().enumerate().take(h) {
        let up = if y == 0 { 0 } else { y - 1 };
        let down = if y + 1 == h { y } else { y + 1 };
        for x in lo..hi {
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

/// A half-open column range `lo..hi`; empty when `lo >= hi`.
type Span = (usize, usize);

/// The union of `a` and `b`.
fn union(a: Span, b: Span) -> Span {
    if a.0 >= a.1 {
        b
    } else if b.0 >= b.1 {
        a
    } else {
        (a.0.min(b.0), a.1.max(b.1))
    }
}

/// `a` widened by one column each side and clipped to `0..len`; empty stays empty.
fn widen(a: Span, len: usize) -> Span {
    if a.0 >= a.1 {
        a
    } else {
        (a.0.saturating_sub(1), (a.1 + 1).min(len))
    }
}

/// `round(x / 255)` for `x <= 65535`.
fn div255(x: u32) -> u32 {
    (x + 128 + ((x + 128) >> 8)) >> 8
}

/// `div255(p * cov + g * (255 - cov))` on each of four 16-bit lanes of 8-bit values. No lane
/// ever exceeds `255 * 255 + 128 + 254`, so no carry crosses a lane.
fn blend(p: u64, g: u64, cov: u32) -> u64 {
    const LOW: u64 = 0x00ff_00ff_00ff_00ff;
    let x = p * cov as u64 + g * (255 - cov) as u64 + 0x0080_0080_0080_0080;
    ((x + ((x >> 8) & LOW)) >> 8) & LOW
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
    /// Per doubled pixel, the blurred mask of every layer: byte `k` is layer `k`'s level,
    /// lowest rank first, and zero past the last layer.
    levels: Vec<[u8; 16]>,
    /// Three rows of horizontal blur sums, one lane per layer as in `levels`.
    weight_rows: Vec<u128>,
    /// Per doubled row, a bit for each pixel whose `levels` changed in the last rebuild.
    level_changes: Vec<u64>,
    /// Per doubled column, scratch for `compose`: the layers that differ from the next.
    tap_diff: Vec<u128>,
    /// Per doubled row, whether any layer is nonzero there.
    layer_ink: [bool; X2_HEIGHT],
    layer_index: [u8; MAX_LAYERS],
    layer_count: usize,
    /// The backdrop and ranks `x2` and `levels` were built for; while they hold, a rebuild
    /// redoes only the columns near window pixels that changed.
    layers_for: Option<([bool; 16], [u16; 16])>,
    /// Edge ramp steepness: coverage gained per mask level, 8.8 fixed point.
    ramp: i64,
    /// Indices seen beside graphics that contrast with both them and the backdrop, under the
    /// current background and palette; their colours are never adjusted for contrast.
    protected: [bool; 16],
    mask: Vec<u8>,
    /// The mask `compose` last read, and per mask row a bit for each pixel that has changed
    /// since.
    mask_prev: Vec<u8>,
    mask_changes: Vec<u64>,
    blur: Vec<u16>,
    cols: Vec<Tap>,
    rows: Vec<Tap>,
    shadow_cols: Vec<Tap>,
    shadow_rows: Vec<Tap>,
    /// Per frame pixel, the graphics over the shadow, rebuilt only when the window, background
    /// or palette changes: premultiplied R, G and B, `255 - alpha`, and the shadow's `keep`.
    overlay: Vec<[u8; 5]>,
    /// Per frame row, whether any overlay pixel there is not empty (`[0, 0, 0, 255, 255]`).
    overlay_ink: Vec<bool>,
    /// What `overlay` was composed with besides `levels` and `mask`: background, colour table
    /// and layer order. While it holds, only pixels reading a changed level or mask recompose.
    composed: Option<(u8, [u64; 16], [u8; MAX_LAYERS], usize)>,
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
            levels: vec![[0; 16]; X2_SIZE],
            level_changes: vec![0; X2_HEIGHT * X2_WORDS],
            weight_rows: vec![0; 3 * X2_WIDTH],
            tap_diff: vec![0; X2_WIDTH],
            layer_ink: [false; X2_HEIGHT],
            layer_index: [0; MAX_LAYERS],
            layer_count: 0,
            layers_for: None,
            // A mask pixel spans `rw / 576` frame pixels; ramp the full 255 over about 0.6
            // frame pixels, but never so gently that a full mask stays translucent.
            ramp: (rw as i64 * 256 / 150).max(MIN_RAMP),
            protected: [false; 16],
            mask: vec![0; MASK_WIDTH * MASK_HEIGHT],
            mask_prev: vec![0; MASK_WIDTH * MASK_HEIGHT],
            mask_changes: vec![0; MASK_HEIGHT * MASK_WORDS],
            blur: vec![0; MASK_WIDTH * MASK_HEIGHT],
            cols: vec![Tap::default(); width],
            rows: vec![Tap::default(); height],
            shadow_cols: vec![Tap::default(); width],
            shadow_rows: vec![Tap::default(); height],
            overlay: vec![[0, 0, 0, 255, 255]; width * height],
            overlay_ink: vec![false; height],
            composed: None,
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
            (rx, rw),
            X2_WIDTH,
            X2_WIDTH - 1,
            0,
            rw * TILE_WIDTH / WINDOW_WIDTH,
        );
        taps(
            &mut presenter.rows,
            (ry, rh),
            X2_HEIGHT,
            X2_HEIGHT - 1,
            0,
            rh * TILE_HEIGHT / WINDOW_HEIGHT,
        );
        // The shadow samples the padded mask out to its far edge, so the shadow of ink at the
        // window's right or bottom edge is not clamped onto the window.
        let (cols, rows) = (&mut presenter.shadow_cols, &mut presenter.shadow_rows);
        taps(cols, (rx, rw), WINDOW_WIDTH, MASK_WIDTH - 1, shift, 0);
        taps(rows, (ry, rh), WINDOW_HEIGHT, MASK_HEIGHT - 1, shift, 0);
        // Outside the rectangle the shadow reads the mask's zero corner.
        for taps in [cols, rows] {
            for tap in taps.iter_mut() {
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
        // Per window row, the columns that changed.
        let mut changed: [Span; WINDOW_HEIGHT] = [(0, 0); WINDOW_HEIGHT];
        for (row, span) in changed.iter_mut().enumerate() {
            let at = (y0 + row) * SCREEN_WIDTH + x0;
            let src = &state.screen[at..at + WINDOW_WIDTH];
            let dst = &mut self.window[row * WINDOW_WIDTH..(row + 1) * WINDOW_WIDTH];
            if dst != src {
                let lo = dst.iter().zip(src).position(|(a, b)| a != b).unwrap_or(0);
                let hi = WINDOW_WIDTH
                    - dst
                        .iter()
                        .zip(src)
                        .rev()
                        .position(|(a, b)| a != b)
                        .unwrap_or(0);
                dst[lo..hi].copy_from_slice(&src[lo..hi]);
                *span = (lo, hi);
                window_changed = true;
            }
        }
        let rebuilt = window_changed || self.built != Some((background, palette));
        if rebuilt {
            let backdrop = backdrop_indices(decoder);
            let rank = ranks(background, &palette);
            // Per window row, the pixels whose doubled 2 x 2 block may differ: those beside a
            // changed pixel, or all of them when the backdrop or ranks moved.
            let partial = self.layers_for == Some((backdrop, rank));
            let mut doubled: [Span; WINDOW_HEIGHT] = [(0, WINDOW_WIDTH); WINDOW_HEIGHT];
            if partial {
                for (y, span) in doubled.iter_mut().enumerate() {
                    let near = &changed[y.saturating_sub(1)..(y + 2).min(WINDOW_HEIGHT)];
                    *span = widen(near.iter().fold((0, 0), |a, &b| union(a, b)), WINDOW_WIDTH);
                }
            }
            scale2x(
                &self.window,
                WINDOW_WIDTH,
                WINDOW_HEIGHT,
                &rank,
                &doubled,
                &mut self.x2,
            );
            self.build_layers(&backdrop, &rank, partial.then_some(&doubled));
            self.layers_for = Some((backdrop, rank));
            self.build_mask(&backdrop, &rank);
            if self
                .built
                .is_some_and(|(b, p)| (b, p) != (background, palette))
            {
                self.protected = [false; 16];
            }
            let colours = self.colours(background, &palette, &backdrop);
            self.compose(background, &colours);
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
        let t = millis.saturating_sub(self.ease_start).clamp(0, EASE_MS);
        for c in 0..3 {
            self.stage[c] = self.from[c] + (self.to[c] - self.from[c]) * t / EASE_MS;
        }
    }

    /// One layer per non-background index present in the doubled window, lowest rank first. A
    /// layer's mask is 255 where the pixel ranks at or above the layer's index, blurred once with
    /// `[1, BLUR_CENTRE, 1]` (separable, edges clamped). Every layer is kept at once, one byte
    /// lane each: the blur sums weighted neighbour counts, and [`level`] turns them into mask
    /// bytes.
    fn build_layers(
        &mut self,
        backdrop: &[bool; 16],
        rank: &[u16; 16],
        doubled: Option<&[Span; WINDOW_HEIGHT]>,
    ) {
        let hidden = (0..16).fold(0u16, |m, i| m | (backdrop[i] as u16) << i);
        let mut seen = 0u16;
        let mut row_shown = [false; X2_HEIGHT];
        for (shown_row, row) in row_shown.iter_mut().zip(self.x2.chunks_exact(X2_WIDTH)) {
            let row_seen = row.iter().fold(0u16, |m, &index| m | 1 << (index & 15));
            *shown_row = row_seen & !hidden != 0;
            seen |= row_seen;
        }
        let previous = (self.layer_index, self.layer_count);
        self.layer_count = 0;
        for i in (0..16).filter(|&i| (seen & !hidden) >> i & 1 != 0) {
            self.layer_index[self.layer_count] = i as u8;
            self.layer_count += 1;
        }
        self.layer_index[..self.layer_count].sort_unstable_by_key(|&i| rank[i as usize]);
        // Per index, a 1 in the lane of every layer it counts towards.
        let mut stack = [0u128; 16];
        for (layer, &floor_index) in self.layer_index[..self.layer_count].iter().enumerate() {
            let floor = rank[floor_index as usize];
            for (j, lanes) in stack.iter_mut().enumerate() {
                if !backdrop[j] && rank[j] >= floor {
                    *lanes |= 1 << (8 * layer);
                }
            }
        }
        let centre = BLUR_CENTRE.trailing_zeros();
        if let Some(doubled) = doubled.filter(|_| previous == (self.layer_index, self.layer_count))
        {
            self.update_levels(&stack, doubled);
            return;
        }
        // Horizontal sums of row `y` into ring slot `y % 3`; false when the row is all zero.
        let horizontal = |x2: &[u8], ring: &mut [u128], y: usize| -> bool {
            let out = &mut ring[(y % 3) * X2_WIDTH..][..X2_WIDTH];
            if !row_shown[y] {
                out.fill(0);
                return false;
            }
            let row = &x2[y * X2_WIDTH..][..X2_WIDTH];
            for x in 0..X2_WIDTH {
                let l = stack[row[x.saturating_sub(1)] as usize];
                let r = stack[row[(x + 1).min(X2_WIDTH - 1)] as usize];
                out[x] = l + (stack[row[x] as usize] << centre) + r;
            }
            true
        };
        let mut nonzero = [false; 3];
        nonzero[0] = horizontal(&self.x2, &mut self.weight_rows, 0);
        for y in 0..X2_HEIGHT {
            let down = (y + 1).min(X2_HEIGHT - 1);
            if down != y {
                nonzero[down % 3] = horizontal(&self.x2, &mut self.weight_rows, down);
            }
            let up = y.saturating_sub(1);
            let out = &mut self.levels[y * X2_WIDTH..][..X2_WIDTH];
            let bits = &mut self.level_changes[y * X2_WORDS..][..X2_WORDS];
            bits.fill(0);
            if !(nonzero[up % 3] || nonzero[y % 3] || nonzero[down % 3]) {
                for (x, level) in out.iter_mut().enumerate() {
                    if *level != [0; 16] {
                        *level = [0; 16];
                        bits[x / 64] |= 1 << (x % 64);
                    }
                }
                self.layer_ink[y] = false;
                continue;
            }
            let ring = &self.weight_rows;
            let (hu, hc, hd) = (
                &ring[(up % 3) * X2_WIDTH..][..X2_WIDTH],
                &ring[(y % 3) * X2_WIDTH..][..X2_WIDTH],
                &ring[(down % 3) * X2_WIDTH..][..X2_WIDTH],
            );
            let mut any = 0;
            for x in 0..X2_WIDTH {
                let w = hu[x] + (hc[x] << centre) + hd[x];
                any |= w;
                let new = level(w).to_le_bytes();
                if out[x] != new {
                    out[x] = new;
                    bits[x / 64] |= 1 << (x % 64);
                }
            }
            self.layer_ink[y] = any != 0;
        }
    }

    /// Recomputes `levels` only where a doubled pixel in `doubled` (per window row, the source
    /// columns `scale2x` redid) falls under the 3 x 3 blur, giving the same levels as a full
    /// build under the same `stack`.
    fn update_levels(&mut self, stack: &[u128; 16], doubled: &[Span; WINDOW_HEIGHT]) {
        let centre = BLUR_CENTRE.trailing_zeros();
        let x2 = &self.x2;
        let horizontal = |y: usize, x: usize| -> u128 {
            let row = &x2[y * X2_WIDTH..][..X2_WIDTH];
            stack[row[x.saturating_sub(1)] as usize]
                + (stack[row[x] as usize] << centre)
                + stack[row[(x + 1).min(X2_WIDTH - 1)] as usize]
        };
        for y in 0..X2_HEIGHT {
            let bits = &mut self.level_changes[y * X2_WORDS..][..X2_WORDS];
            bits.fill(0);
            let up = y.saturating_sub(1);
            let down = (y + 1).min(X2_HEIGHT - 1);
            let source = |r: usize| {
                let (lo, hi) = doubled[r / 2];
                (2 * lo, 2 * hi)
            };
            let (lo, hi) = widen(union(union(source(up), source(y)), source(down)), X2_WIDTH);
            if lo >= hi {
                continue;
            }
            let out = &mut self.levels[y * X2_WIDTH..][..X2_WIDTH];
            let mut moved = false;
            for x in lo..hi {
                let w = horizontal(up, x) + (horizontal(y, x) << centre) + horizontal(down, x);
                let new = level(w).to_le_bytes();
                if out[x] != new {
                    out[x] = new;
                    bits[x / 64] |= 1 << (x % 64);
                    moved = true;
                }
            }
            if moved {
                self.layer_ink[y] = out.iter().any(|l| *l != [0; 16]);
            }
        }
    }

    /// Marks ink pixels 255 in the padded mask and box blurs it twice (radius 1, separable).
    /// Ink is any index outside the backdrop whose colour is at least [`INK_DISTANCE`]
    /// (squared, in 4-bit levels) from the background colour.
    fn build_mask(&mut self, backdrop: &[bool; 16], rank: &[u16; 16]) {
        let mut ink = [false; 16];
        for (i, flag) in ink.iter_mut().enumerate() {
            *flag = !backdrop[i] && ((rank[i] as i32 - 1) >> 4) >= INK_DISTANCE;
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
        let rows = self.mask.chunks_exact(MASK_WIDTH);
        let prev = self.mask_prev.chunks_exact_mut(MASK_WIDTH);
        for ((row, prev), bits) in rows
            .zip(prev)
            .zip(self.mask_changes.chunks_exact_mut(MASK_WORDS))
        {
            bits.fill(0);
            for (x, (&m, p)) in row.iter().zip(prev.iter_mut()).enumerate() {
                if m != *p {
                    *p = m;
                    bits[x / 64] |= 1 << (x % 64);
                }
            }
        }
    }

    /// The drawn colour of each index: its palette colour, or for a colour that touches the
    /// backdrop with less than [`MIN_CONTRAST_X10`] against the backdrop's darkest or brightest
    /// point, that colour mixed toward white or black by the fewest sixteenths that reach it.
    /// Outlined colours keep theirs: an index is protected once its window boundary with some
    /// graphics index that both contrasts with it and is legible on the backdrop is at least a
    /// third of its boundary with the backdrop. Protection lasts until the background or palette
    /// changes, so a colour does not flip while its outline draws in.
    fn colours(
        &mut self,
        background: u8,
        palette: &[u16; 16],
        backdrop: &[bool; 16],
    ) -> [[i64; 3]; 16] {
        let rgb = palette.map(|entry| colour_8_8(entry).map(|v| v >> 8));
        let lum = rgb.map(luminance);
        let target = MIN_CONTRAST_X10 * 1024 / 10;
        let (dark, bright) = backdrop_range(colour_8_8(palette[background as usize]));
        let legible_on_stage = lum.map(|l| worst_x1024(l, dark, bright) >= target);
        // Window boundary lengths: of each index with the backdrop, and of each pair of
        // contrasting graphics indices.
        let mut back = [0u32; 16];
        let mut held = [[0u32; 16]; 16];
        let mut pair = |a: u8, b: u8| {
            if a == b {
                return;
            }
            let (a, b) = (a as usize, b as usize);
            match (backdrop[a], backdrop[b]) {
                (true, true) => {}
                (false, true) => back[a] += 1,
                (true, false) => back[b] += 1,
                (false, false) => {
                    if contrast_x1024(lum[a], lum[b]) >= target {
                        held[a][b] += 1;
                        held[b][a] += 1;
                    }
                }
            }
        };
        for y in 0..WINDOW_HEIGHT {
            let row = &self.window[y * WINDOW_WIDTH..(y + 1) * WINDOW_WIDTH];
            for x in 0..WINDOW_WIDTH {
                if x + 1 < WINDOW_WIDTH {
                    pair(row[x], row[x + 1]);
                }
                if y + 1 < WINDOW_HEIGHT {
                    pair(row[x], self.window[(y + 1) * WINDOW_WIDTH + x]);
                }
            }
        }
        for i in 0..16 {
            for j in 0..16 {
                if legible_on_stage[j] && held[i][j] > 0 && held[i][j] * 3 >= back[i] {
                    self.protected[i] = true;
                }
            }
        }
        let mut out = rgb;
        for i in 0..16 {
            let graphics = i as u8 != background && !backdrop[i];
            if graphics && back[i] > 0 && !legible_on_stage[i] && !self.protected[i] {
                out[i] = legible(rgb[i], dark, bright);
            }
        }
        out
    }

    /// Composes the graphics layers and the shadow into `overlay`.
    fn compose(&mut self, background: u8, colours: &[[i64; 3]; 16]) {
        // Premultiplied colour of each index; the background index is transparent.
        // Held as four 16-bit lanes, R lowest, for `blend`.
        let mut lut = [0u64; 16];
        for (i, entry) in lut.iter_mut().enumerate() {
            if i as u8 != background {
                let [r, g, b] = colours[i].map(|v| v as u64);
                *entry = r | g << 16 | b << 32 | 255 << 48;
            }
        }
        // Source rows holding any ink: an output row whose shadow and graphics taps all read
        // empty rows is the empty pixel throughout (no shadow, and layer 0, which every later
        // layer nests inside, is zero at every tap).
        let mut mask_ink = [false; MASK_HEIGHT];
        for (ink, row) in mask_ink.iter_mut().zip(self.mask.chunks_exact(MASK_WIDTH)) {
            *ink = row.iter().any(|&m| m != 0);
        }
        let layer_ink = self.layer_ink;
        let key = (background, lut, self.layer_index, self.layer_count);
        // Every pixel reads only that key, `levels` and `mask`; with the key unchanged, only a
        // pixel with a changed tap can change.
        let all = self.composed != Some(key);
        self.composed = Some(key);
        let width = self.width;
        // Bounded by `MAX_RAMP`, so coverage arithmetic fits `i32`.
        let ramp = self.ramp as i32;
        let mut tap_diff = core::mem::take(&mut self.tap_diff);
        for (y, line) in self.overlay.chunks_exact_mut(width).enumerate() {
            let ry = self.rows[y];
            let sy = self.shadow_rows[y];
            let level_bits = |row: u32| &self.level_changes[row as usize * X2_WORDS..][..X2_WORDS];
            let mask_bits =
                |row: u32| &self.mask_changes[row as usize * MASK_WORDS..][..MASK_WORDS];
            let mut lv = [0u64; X2_WORDS];
            for (k, w) in lv.iter_mut().enumerate() {
                *w = level_bits(ry.i0)[k] | level_bits(ry.i1)[k];
            }
            let mut mk = [0u64; MASK_WORDS];
            for (k, w) in mk.iter_mut().enumerate() {
                *w = mask_bits(sy.i0)[k] | mask_bits(sy.i1)[k];
            }
            if !all && lv == [0; X2_WORDS] && mk == [0; MASK_WORDS] {
                continue;
            }
            // An empty row's pixels all compose to the empty pixel, so an empty row that turns
            // inked keeps them where nothing changed.
            let inked = mask_ink[sy.i0 as usize]
                || mask_ink[sy.i1 as usize]
                || (ry.edge != 0 && (layer_ink[ry.i0 as usize] || layer_ink[ry.i1 as usize]));
            self.overlay_ink[y] = inked;
            if !inked {
                line.fill([0, 0, 0, 255, 255]);
                continue;
            }
            let r0 = &self.levels[ry.i0 as usize * X2_WIDTH..][..X2_WIDTH];
            let r1 = &self.levels[ry.i1 as usize * X2_WIDTH..][..X2_WIDTH];
            if ry.edge != 0 {
                // Per doubled column, which layers differ from the next at the source rows with
                // nonzero weight.
                let lower = if ry.f != 0 { u128::MAX } else { 0 };
                for (d, (a, b)) in tap_diff.iter_mut().zip(r0.iter().zip(r1)) {
                    *d = next_differs(u128::from_le_bytes(*a))
                        | (next_differs(u128::from_le_bytes(*b)) & lower);
                }
            }
            let (fy0, fy1) = (256 - ry.f, ry.f);
            let m0 = &self.mask[sy.i0 as usize * MASK_WIDTH..][..MASK_WIDTH];
            let m1 = &self.mask[sy.i1 as usize * MASK_WIDTH..][..MASK_WIDTH];
            for (x, px) in line.iter_mut().enumerate() {
                let sx = self.shadow_cols[x];
                let rx = self.cols[x];
                if !all
                    && !(changed(&lv, rx.i0)
                        || changed(&lv, rx.i1)
                        || changed(&mk, sx.i0)
                        || changed(&mk, sx.i1))
                {
                    continue;
                }
                let top =
                    m0[sx.i0 as usize] as u32 * (256 - sx.f) + m0[sx.i1 as usize] as u32 * sx.f;
                let bottom =
                    m1[sx.i0 as usize] as u32 * (256 - sx.f) + m1[sx.i1 as usize] as u32 * sx.f;
                let m = (top * (256 - sy.f) + bottom * sy.f) >> 16;
                let keep = 255 - div255(m * SHADOW_ALPHA);
                let mut g = 0u64;
                let edge = rx.edge * ry.edge;
                // A layer is drawn where its weighted taps differ from the next layer's: one
                // whose taps equal the next's holds none of its own index in their blur
                // support, and drawing it would only fringe the next one. A tap with zero
                // bilinear weight takes no part. Layers nest, so a drawn layer is never empty,
                // and lanes past the last layer are zero.
                let (i0, i1) = (rx.i0 as usize, rx.i1 as usize);
                let differs = match (edge, rx.f) {
                    (0, _) => 0,
                    (_, 0) => tap_diff[i0],
                    _ => tap_diff[i0] | tap_diff[i1],
                };
                if differs != 0 {
                    let mut drawn = nonzero_lanes(differs);
                    let taps = [&r0[i0], &r0[i1], &r1[i0], &r1[i1]];
                    let (fx0, fx1) = (256 - rx.f, rx.f);
                    let mut covs = [0u8; 16];
                    let mut partial = 0u32;
                    // Top layer down: a fully covering layer hides every layer below it, so
                    // blending starts at the highest one.
                    while drawn != 0 {
                        let layer = (31 - drawn.leading_zeros()) as usize;
                        drawn &= !(1 << layer);
                        // Mask level in 8.8 fixed point: bilinear, rows first.
                        let t0 = taps[0][layer] as u32 * fy0 + taps[2][layer] as u32 * fy1;
                        let t1 = taps[1][layer] as u32 * fy0 + taps[3][layer] as u32 * fy1;
                        let v = (t0 * fx0 + t1 * fx1) >> 8;
                        let cov = ((((v as i32 - EDGE_THRESHOLD as i32 * 256) * ramp) >> 16) + 128)
                            .clamp(0, 255) as u32;
                        if cov == 255 {
                            g = lut[self.layer_index[layer] as usize];
                            break;
                        }
                        covs[layer] = cov as u8;
                        partial |= ((cov != 0) as u32) << layer;
                    }
                    while partial != 0 {
                        let layer = partial.trailing_zeros() as usize;
                        partial &= partial - 1;
                        g = blend(lut[self.layer_index[layer] as usize], g, covs[layer] as u32);
                    }
                }
                let mut g = [0, 16, 32, 48].map(|shift| (g >> shift) as u32 & 0xffff);
                if edge != 1 << 16 {
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
        self.tap_diff = tap_diff;
    }

    /// Draws the backdrop at `millis` under the overlay into `frame`. The backdrop row is
    /// sampled every [`BACKDROP_STEP`] pixels and at the last pixel and linearly interpolated
    /// between samples (rounding half up), fused here with the dither and blend.
    fn draw(&mut self, millis: i64) {
        let backdrop = Backdrop::new(self.stage, self.width as i64, self.height as i64, millis);
        let width = self.width;
        let last = width - 1;
        let rows = self.frame.chunks_exact_mut(width * 4);
        for (y, (line, over)) in rows.zip(self.overlay.chunks_exact(width)).enumerate() {
            let bayer = BAYER[y & 3].map(|b| b * 16 + 8);
            if !self.overlay_ink[y] {
                bare_row(&backdrop, y as i64, line, &bayer);
                continue;
            }
            let mut a = backdrop.sample(0, y as i64);
            shade(&mut line[..4], &over[0], a, bayer[0]);
            let mut x0 = 0;
            while x0 < last {
                let x1 = (x0 + BACKDROP_STEP).min(last);
                let b = backdrop.sample(x1 as i64, y as i64);
                let span = (x1 - x0) as u32;
                let pixels = line[(x0 + 1) * 4..x1 * 4].chunks_exact_mut(4);
                let overs = &over[x0 + 1..x1];
                if span == BACKDROP_STEP as u32 {
                    // The common full step: (a * (8 - t) + b * t + 4) >> 3, stepped by b - a in
                    // wrapping arithmetic (every partial sum is the non-negative true value).
                    let mut acc = a.map(|v| v * 8 + 4);
                    let d = [0, 1, 2].map(|c| b[c].wrapping_sub(a[c]));
                    for (k, (px, o)) in pixels.zip(overs).enumerate() {
                        for c in 0..3 {
                            acc[c] = acc[c].wrapping_add(d[c]);
                        }
                        let stage = acc.map(|v| v >> STEP_SHIFT);
                        shade(px, o, stage, bayer[(x0 + 1 + k) & 3]);
                    }
                } else {
                    for (k, (px, o)) in pixels.zip(overs).enumerate() {
                        let t = k as u32 + 1;
                        let stage =
                            [0, 1, 2].map(|c| (a[c] * (span - t) + b[c] * t + span / 2) / span);
                        shade(px, o, stage, bayer[(x0 + 1 + k) & 3]);
                    }
                }
                shade(&mut line[x1 * 4..x1 * 4 + 4], &over[x1], b, bayer[x1 & 3]);
                a = b;
                x0 = x1;
            }
        }
    }
}

/// A row with an empty overlay: the dithered backdrop alone, which is what [`shade`] gives for
/// an empty overlay pixel.
fn bare_row(backdrop: &Backdrop, y: i64, line: &mut [u8], bayer: &[u32; 4]) {
    let last = line.len() / 4 - 1;
    let put = |px: &mut [u8], stage: [u32; 3], threshold: u32| {
        for c in 0..3 {
            px[c] = ((stage[c] + threshold) >> 8) as u8;
        }
        px[3] = 255;
    };
    let mut a = backdrop.sample(0, y);
    put(&mut line[..4], a, bayer[0]);
    let mut x0 = 0;
    while x0 < last {
        let x1 = (x0 + BACKDROP_STEP).min(last);
        let b = backdrop.sample(x1 as i64, y);
        let span = (x1 - x0) as u32;
        let pixels = line[(x0 + 1) * 4..x1 * 4].chunks_exact_mut(4);
        if span == BACKDROP_STEP as u32 {
            // x0 is a multiple of 8, so pixel x0 + 1 + k takes Bayer column (1 + k) & 3.
            let mut acc = a.map(|v| v * 8 + 4);
            let d = [0, 1, 2].map(|c| b[c].wrapping_sub(a[c]));
            for (k, px) in pixels.enumerate() {
                for c in 0..3 {
                    acc[c] = acc[c].wrapping_add(d[c]);
                }
                put(px, acc.map(|v| v >> STEP_SHIFT), bayer[(1 + k) & 3]);
            }
        } else {
            for (k, px) in pixels.enumerate() {
                let t = k as u32 + 1;
                let stage = [0, 1, 2].map(|c| (a[c] * (span - t) + b[c] * t + span / 2) / span);
                put(px, stage, bayer[(x0 + 1 + k) & 3]);
            }
        }
        put(&mut line[x1 * 4..x1 * 4 + 4], b, bayer[x1 & 3]);
        a = b;
        x0 = x1;
    }
}

/// One output pixel: the stage (8.8, at most 65280) dithered by `threshold` (at most 248, so the
/// sum stays within 8 bits after the shift), shaded and cleared by the overlay, plus its colour.
#[inline(always)]
fn shade(px: &mut [u8], o: &[u8; 5], stage: [u32; 3], threshold: u32) {
    let (keep, clear) = (o[4] as u32, o[3] as u32);
    if keep == 255 && clear == 255 {
        // No graphics and no shadow: div255(v * 255) == v, so the pixel is the dithered stage
        // plus the (zero-alpha) overlay.
        for c in 0..3 {
            let s = (stage[c] + threshold) >> 8;
            px[c] = (o[c] as u32 + s).min(255) as u8;
        }
    } else {
        for c in 0..3 {
            let s = (stage[c] + threshold) >> 8;
            let shade = div255(s * keep);
            px[c] = (o[c] as u32 + div255(shade * clear)).min(255) as u8;
        }
    }
    px[3] = 255;
}

/// Relative luminance of an 8-bit colour, 0..=65025: the Rec. 709 weights (54, 183, 19 of 256)
/// over each channel squared, a gamma-2 stand-in for the sRGB transfer curve.
fn luminance([r, g, b]: [i64; 3]) -> i64 {
    (54 * r * r + 183 * g * g + 19 * b * b) >> 8
}

/// Contrast ratio of two luminances times 1024, with the WCAG flare of 0.05 (3251 of 65025).
fn contrast_x1024(a: i64, b: i64) -> i64 {
    let (hi, lo) = if a >= b { (a, b) } else { (b, a) };
    (hi + 3251) * 1024 / (lo + 3251)
}

/// Luminances bounding every backdrop point for a stage colour in 8.8 fixed point. Each backdrop
/// channel is a chain of rounded blends, each monotone in its input and in its weight (the two
/// glow weights, 0 up to their strengths, and the vignette factor), so its extremes lie at the
/// corners of that box; luminance grows with every channel, so
/// the per-channel minimum and maximum over the eight corners bound it from below and above.
fn backdrop_range(stage: [i64; 3]) -> (i64, i64) {
    let lighten = |v: i64, k: i64| v + (65280 - v) * k / 1024;
    let base = stage.map(|v| v * BASE_LEVEL / 1024 + (6 << 8));
    let warm = [0, 1, 2].map(|c| lighten((stage[c] + stage[(c + 2) % 3]) / 2, 80));
    let light = stage.map(|v| lighten(v, 180));
    let (mut lo, mut hi) = ([i64::MAX; 3], [0i64; 3]);
    for corner in 0..8 {
        let mut c = base;
        for (bit, (colour, strength)) in [(light, 36_000), (warm, 30_000)].into_iter().enumerate() {
            let a = if corner >> bit & 1 == 1 { strength } else { 0 };
            for ch in 0..3 {
                c[ch] += ((colour[ch] - c[ch]) * a) >> 16;
            }
        }
        let v = if corner & 4 == 4 {
            65536 - 30_000
        } else {
            65536
        };
        for ch in 0..3 {
            let px = ((c[ch] * v) >> 16).clamp(0, 65280) >> 8;
            lo[ch] = lo[ch].min(px);
            hi[ch] = hi[ch].max(px);
        }
    }
    (luminance(lo), luminance(hi))
}

/// The lowest contrast of luminance `l` against the backdrop: 1:1 (1024) inside `dark..=bright`,
/// where some backdrop point may match it, else against the nearer end.
fn worst_x1024(l: i64, dark: i64, bright: i64) -> i64 {
    if (dark..=bright).contains(&l) {
        1024
    } else {
        contrast_x1024(l, dark).min(contrast_x1024(l, bright))
    }
}

/// `rgb` mixed toward white or black by the fewest sixteenths (white first) whose [`worst_x1024`]
/// contrast reaches [`MIN_CONTRAST_X10`]; when none does, the mix (fewest
/// sixteenths, white first, unmixed before both) with the best worse contrast.
fn legible(rgb: [i64; 3], dark: i64, bright: i64) -> [i64; 3] {
    let worst = |c: [i64; 3]| worst_x1024(luminance(c), dark, bright);
    let target = MIN_CONTRAST_X10 * 1024 / 10;
    let mut best = (worst(rgb), rgb);
    if best.0 >= target {
        return rgb;
    }
    for k in 1..=16 {
        for c in [
            rgb.map(|v| v + (255 - v) * k / 16),
            rgb.map(|v| v * (16 - k) / 16),
        ] {
            let w = worst(c);
            if w >= target {
                return c;
            }
            if w > best.0 {
                best = (w, c);
            }
        }
    }
    best.1
}

/// `0..=65536` and back over `period` ms, eased at both ends (smoothstep of a triangle wave).
fn drift(millis: i64, period: i64) -> i64 {
    let t = millis.rem_euclid(period);
    let tri = (2 * t * 65536 / period - 65536).abs();
    (((tri * tri) >> 16) * (3 * 65536 - 2 * tri)) >> 16
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
            let cy = height
                * (y[0] + (y[1] - y[0]) * drift(millis.rem_euclid(py) + px / 3, py) / 65536)
                / 100;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cdg::{BORDER_X, BORDER_Y};

    #[test]
    fn level_rounds_every_count_in_every_lane() {
        for count in 0..=BLUR_AREA as u8 {
            let want = ((255 * count as u32 + BLUR_AREA / 2) / BLUR_AREA) as u8;
            for lane in 0..16 {
                let mut counts = [0u8; 16];
                counts[lane] = count;
                counts[(lane + 1) % 16] = BLUR_AREA as u8;
                let got = level(u128::from_le_bytes(counts)).to_le_bytes();
                assert_eq!(got[lane], want, "count {count} lane {lane}");
                assert_eq!(got[(lane + 1) % 16], 255);
            }
        }
    }

    /// Colour 0 black, 1 white, 2 red, then one XOR tile per `(window x, window y, colour)`
    /// inking that single window pixel.
    fn pixel_stream(pixels: &[(usize, usize, u8)]) -> Vec<u8> {
        let pack = |instruction: u8, data: [u8; 16]| {
            let mut p = [0u8; 24];
            p[0] = 9;
            p[1] = instruction;
            p[4..20].copy_from_slice(&data);
            p
        };
        let mut palette = [0u8; 16];
        palette[2..6].copy_from_slice(&[0x3f, 0x3f, 0x3c, 0x00]);
        let mut out = Vec::new();
        out.extend_from_slice(&pack(1, [0; 16]));
        out.extend_from_slice(&pack(30, palette));
        for &(x, y, colour) in pixels {
            let (sx, sy) = (x + BORDER_X, y + BORDER_Y);
            let mut data = [0u8; 16];
            data[1] = colour;
            data[2] = (sy / TILE_HEIGHT) as u8;
            data[3] = (sx / TILE_WIDTH) as u8;
            data[4 + sy % TILE_HEIGHT] = 0x20 >> (sx % TILE_WIDTH);
            out.extend_from_slice(&pack(38, data));
        }
        out
    }

    fn present_pixels(width: usize, height: usize, pixels: &[(usize, usize, u8)]) -> Presenter {
        let stream = pixel_stream(pixels);
        let mut decoder = Decoder::new(&stream);
        decoder.advance_to(decoder.pack_count());
        let window = |x: usize, y: usize| {
            decoder.state().screen[(y + BORDER_Y) * SCREEN_WIDTH + x + BORDER_X]
        };
        for &(x, y, colour) in pixels {
            assert_eq!(window(x, y), colour, "stream inks window ({x}, {y})");
        }
        let mut presenter = Presenter::new(width, height).unwrap();
        presenter.present(&decoder, 0);
        presenter
    }

    #[test]
    fn zero_weight_taps_do_not_fringe() {
        // At exactly twice the window, frame (200, 160) samples doubled cell (200, 160) with
        // both fractions zero, so red one window pixel to the right must not tint it.
        let at = (160 * 576 + 200) * 4;
        let white = present_pixels(576, 384, &[(100, 80, 1)]);
        let both = present_pixels(576, 384, &[(100, 80, 1), (101, 80, 2)]);
        assert_eq!(white.frame[at..at + 4], both.frame[at..at + 4]);
    }

    #[test]
    fn lone_pixel_draws_at_twice_the_window_and_above() {
        // Inside the one-tile feather band at the window edge, and wherever the rectangle is
        // smaller than the doubled grid (a lone pixel at window (35, 35) at 300x200), the frame
        // may sample between the pixel's peaks; elsewhere every placement on a uniform
        // surround draws (two neighbour indices on a diagonal can let scale2x trim the pixel).
        for (width, height) in [(576, 384), (700, 470), (960, 540)] {
            for y in [12, 95, 96, 97, 179] {
                for x in [6, 143, 144, 145, 281] {
                    let presenter = present_pixels(width, height, &[(x, y, 1)]);
                    assert!(
                        presenter.overlay.iter().any(|px| px[3] != 255),
                        "window ({x}, {y}) at {width}x{height}"
                    );
                }
            }
        }
    }

    /// A stream of random XOR tiles, with a palette load, memory presets, border presets and
    /// scrolls mixed in, so rebuilds see changed spans, layer sets and backgrounds.
    fn busy_stream(packs: usize) -> Vec<u8> {
        let mut seed = 0x1234_5678_u64;
        let mut next = move |bound: u32| {
            seed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            ((seed >> 32) as u32) % bound
        };
        let mut out = Vec::new();
        for i in 0..packs {
            let mut p = [0u8; 24];
            p[0] = 9;
            let mut data = [0u8; 16];
            for d in &mut data {
                *d = next(64) as u8;
            }
            p[1] = match (i, next(100)) {
                (0, _) => 1,
                (1, _) => 30,
                (2, _) => 31,
                (_, 0) => 1,
                (_, 1) => 2,
                (_, 2) => 24,
                (_, 3) => 20,
                (_, 4) => 30,
                (_, 5..=40) => 6,
                _ => 38,
            };
            if matches!(p[1], 6 | 38) {
                data[0] &= 15;
                data[1] &= 15;
                data[2] = next(18) as u8;
                data[3] = next(50) as u8;
            }
            p[4..20].copy_from_slice(&data);
            out.extend_from_slice(&p);
        }
        out
    }

    #[test]
    fn partial_rebuilds_match_full_rebuilds() {
        let stream = busy_stream(3_000);
        let mut decoder = Decoder::new(&stream);
        let mut kept = Presenter::new(213, 120).unwrap();
        // Forward in uneven steps, one backward seek, then single packs.
        let mut targets: Vec<u64> = (0..60).map(|i| i * i / 2 + i).collect();
        targets.extend([400, 900, 901, 902, 903, 910, 2_999]);
        for (step, &applied) in targets.iter().enumerate() {
            decoder.advance_to(applied);
            kept.present(&decoder, step as i64 * 33);
            // Protection only grows under one background and palette; start from the same set.
            let mut fresh = Presenter::new(213, 120).unwrap();
            fresh.protected = kept.protected;
            fresh.present(&decoder, step as i64 * 33);
            assert!(
                kept.protected == fresh.protected,
                "protected at pack {applied}"
            );
            assert!(kept.levels == fresh.levels, "levels at pack {applied}");
            assert!(
                kept.layer_ink == fresh.layer_ink,
                "layer ink at pack {applied}"
            );
            assert!(kept.overlay == fresh.overlay, "overlay at pack {applied}");
            assert!(
                kept.overlay_ink == fresh.overlay_ink,
                "overlay ink at pack {applied}"
            );
        }
    }
}
