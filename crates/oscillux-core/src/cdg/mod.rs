// SPDX-License-Identifier: AGPL-3.0-only
//! CD+G (CD graphics) subcode decoder: lyric screens decoded from a pack stream.
//!
//! A CD+G stream is a sequence of 24-byte packs played at 300 packs per second. Byte 0 masked
//! with `0x3F` is the command; only `0x09` (TV graphics) is decoded and every other command is
//! ignored. Byte 1 masked with `0x3F` is the instruction, bytes 4..20 masked with `0x3F` are the
//! 16 data symbols, and the Q parity (bytes 2..4) and P parity (bytes 20..24) are never read.
//!
//! The decoder keeps the 300 x 216 indexed screen (50 x 18 tiles of 6 x 12 pixels), the 16-entry
//! colour table of 12-bit RGB, the transparent-colour table and the scroll offsets. The visible
//! window is 288 x 192 pixels inside a 6-pixel (horizontal) and 12-pixel (vertical) border, moved
//! right and down by the horizontal (0..=5) and vertical (0..=11) scroll offsets.
//!
//! [`Decoder::new`] copies the stream and decodes it once, keeping checkpoints of the decoder
//! state wherever the replay work since the previous checkpoint reaches a fixed budget, so a seek
//! to any position restores at most one checkpoint and replays a bounded number of packs. All
//! allocation happens there; advancing, seeking and reading never allocate, lock or do I/O.
//! Everything is integer arithmetic, so every target decodes the same bytes.

mod state;

use alloc::vec::Vec;

pub use state::State;

/// Bytes per pack.
pub const PACK_SIZE: usize = 24;
/// Packs per second of media time.
pub const PACKS_PER_SECOND: u32 = 300;
/// Screen width in pixels, border included.
pub const SCREEN_WIDTH: usize = 300;
/// Screen height in pixels, border included.
pub const SCREEN_HEIGHT: usize = 216;
/// Screen pixel count; one colour index per pixel.
pub const SCREEN_PIXELS: usize = SCREEN_WIDTH * SCREEN_HEIGHT;
/// Visible window width in pixels.
pub const WINDOW_WIDTH: usize = 288;
/// Visible window height in pixels.
pub const WINDOW_HEIGHT: usize = 192;
/// Bytes of one RGBA8 visible window.
pub const WINDOW_RGBA_BYTES: usize = WINDOW_WIDTH * WINDOW_HEIGHT * 4;
/// Left border width: the window's left edge at horizontal offset 0.
pub const BORDER_X: usize = 6;
/// Top border height: the window's top edge at vertical offset 0.
pub const BORDER_Y: usize = 12;
/// Tile width in pixels.
pub const TILE_WIDTH: usize = 6;
/// Tile height in pixels.
pub const TILE_HEIGHT: usize = 12;

/// The TV-graphics command (byte 0 masked with `0x3F`).
pub const COMMAND_TV_GRAPHICS: u8 = 0x09;
/// Memory Preset: fill the whole screen with one colour.
pub const INSTRUCTION_MEMORY_PRESET: u8 = 1;
/// Border Preset: fill the border with one colour.
pub const INSTRUCTION_BORDER_PRESET: u8 = 2;
/// Tile Block (normal): write one 6 x 12 tile in two colours.
pub const INSTRUCTION_TILE_NORMAL: u8 = 6;
/// Scroll Preset: scroll, filling the vacated strip with a colour.
pub const INSTRUCTION_SCROLL_PRESET: u8 = 20;
/// Scroll Copy: scroll, wrapping the screen around.
pub const INSTRUCTION_SCROLL_COPY: u8 = 24;
/// Define Transparent Colour: one 6-bit transparency per colour index.
pub const INSTRUCTION_DEFINE_TRANSPARENT: u8 = 28;
/// Load Colour Table entries 0..=7.
pub const INSTRUCTION_LOAD_COLOURS_LOW: u8 = 30;
/// Load Colour Table entries 8..=15.
pub const INSTRUCTION_LOAD_COLOURS_HIGH: u8 = 31;
/// Tile Block XOR: exclusive-or one 6 x 12 tile in two colours into the screen.
pub const INSTRUCTION_TILE_XOR: u8 = 38;

/// Replay work, in tile-block units, after which loading takes a checkpoint. A full-screen
/// instruction counts as [`FULL_SCREEN_COST`] units, every other decoded pack as one, so a seek
/// replays at most this much work after restoring one checkpoint.
pub const CHECKPOINT_BUDGET: u32 = 2048;
/// Replay cost of an instruction that rewrites the whole screen (Memory Preset and the scrolls).
pub const FULL_SCREEN_COST: u32 = 64;

/// Bit of [`Decoder::changes`]: some screen indices may have changed (see [`Decoder::dirty`]).
pub const CHANGED_SCREEN: u32 = 1;
/// Bit of [`Decoder::changes`]: the colour table changed.
pub const CHANGED_PALETTE: u32 = 2;
/// Bit of [`Decoder::changes`]: the transparent-colour table changed.
pub const CHANGED_TRANSPARENCY: u32 = 4;
/// Bit of [`Decoder::changes`]: a scroll offset (and so the visible window) changed.
pub const CHANGED_SCROLL: u32 = 8;
/// Bit of [`Decoder::changes`]: the memory-preset or border-preset colour changed.
pub const CHANGED_PRESETS: u32 = 16;

/// Which screen pixels a host shows as transparent, so the visual shows through them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    /// Every pixel is opaque.
    None,
    /// The stream's transparent-colour table: colour `i` gets alpha
    /// `((63 - t[i]) * 255 + 31) / 63`, so 0 is opaque and 63 fully transparent.
    TransparentTable,
    /// Pixels of the most recent Memory Preset (background) colour are transparent.
    PresetColour,
    /// Pixels of this colour index (0..=15) are transparent.
    Index(u8),
    /// Pixels of every colour index `i` whose bit `1 << i` is set are transparent.
    Mask(u16),
}

/// Which window pixels [`Decoder::index_counts`] counts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Region {
    /// The whole 288 x 192 visible window.
    Window,
    /// The window's outer ring one tile deep ([`EDGE_PIXELS`] pixels): window columns `x < 6`
    /// or `x >= 282` and rows `y < 12` or `y >= 180`, where a disc's background shows even when
    /// lyrics fill the middle.
    Edge,
}

/// Pixels in [`Region::Edge`].
pub const EDGE_PIXELS: usize = WINDOW_WIDTH * WINDOW_HEIGHT
    - (WINDOW_WIDTH - 2 * TILE_WIDTH) * (WINDOW_HEIGHT - 2 * TILE_HEIGHT);

/// Why a stream or request was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CdgError {
    /// The media time was NaN.
    Time,
    /// A [`Key::Index`] above 15.
    KeyIndex,
    /// An output buffer had the wrong length.
    Length,
}

/// Small state stored per checkpoint; the screen is stored separately, packed at 4 bits.
#[derive(Clone, Copy)]
struct Checkpoint {
    applied: u64,
    small: state::Small,
}

/// A loaded stream, its checkpoints and the state at the current position.
pub struct Decoder {
    packs: Vec<u8>,
    pack_count: u64,
    checkpoints: Vec<Checkpoint>,
    /// Checkpoint screens, `SCREEN_PIXELS / 2` bytes each, two pixels per byte (low nibble first).
    screens: Vec<u8>,
    state: State,
    applied: u64,
    dirty: [u16; 4],
    changes: u32,
}

impl Decoder {
    /// Copies `stream` (whole packs; a trailing partial pack is ignored) and decodes it once to
    /// place checkpoints. The decoder starts at position 0, before the first pack.
    pub fn new(stream: &[u8]) -> Self {
        let pack_count = (stream.len() / PACK_SIZE) as u64;
        let packs = stream[..pack_count as usize * PACK_SIZE].to_vec();
        let mut state = State::new();
        let mut checkpoints = Vec::new();
        let mut screens = Vec::new();
        let mut cost = 0u32;
        let mut ignored = [0u16; 4];
        push_checkpoint(&mut checkpoints, &mut screens, &state, 0);
        for (index, pack) in packs.chunks_exact(PACK_SIZE).enumerate() {
            cost += state.apply(pack, &mut ignored);
            if cost >= CHECKPOINT_BUDGET {
                push_checkpoint(&mut checkpoints, &mut screens, &state, index as u64 + 1);
                cost = 0;
            }
        }
        state.reset();
        Decoder {
            packs,
            pack_count,
            checkpoints,
            screens,
            state,
            applied: 0,
            dirty: [0; 4],
            changes: 0,
        }
    }

    /// Number of whole packs in the stream.
    pub fn pack_count(&self) -> u64 {
        self.pack_count
    }

    /// Number of checkpoints made at load (the first is position 0).
    pub fn checkpoint_count(&self) -> usize {
        self.checkpoints.len()
    }

    /// Number of packs decoded at the current position.
    pub fn applied(&self) -> u64 {
        self.applied
    }

    /// The position for media time `seconds`: pack `floor(seconds * 300)` and every pack before
    /// it are decoded, so the result is that index plus one, clamped to the stream. Negative
    /// times are position 0; NaN is refused.
    pub fn position_for_time(&self, seconds: f64) -> Result<u64, CdgError> {
        if seconds.is_nan() {
            return Err(CdgError::Time);
        }
        if seconds < 0.0 {
            return Ok(0);
        }
        // A non-negative product truncates to its floor; `as` saturates for huge values.
        let pack = (seconds * PACKS_PER_SECOND as f64) as u64;
        Ok(pack.saturating_add(1).min(self.pack_count))
    }

    /// Advances (or seeks) to the media time `seconds`; see [`Decoder::position_for_time`].
    pub fn advance_to_time(&mut self, seconds: f64) -> Result<(), CdgError> {
        let target = self.position_for_time(seconds)?;
        self.advance_to(target);
        Ok(())
    }

    /// Advances or seeks so the first `applied` packs (clamped to the stream) are decoded.
    /// Moving forward within the current checkpoint span replays from the current position;
    /// otherwise the latest checkpoint at or before the target is restored first. The dirty
    /// rectangle and change bits then describe this call alone.
    pub fn advance_to(&mut self, applied: u64) {
        let target = applied.min(self.pack_count);
        let before = self.state.small();
        let mut dirty = [0u16; 4];
        // The latest checkpoint at or before the target (checkpoint 0 is position 0).
        let slot = self.checkpoints.partition_point(|c| c.applied <= target) - 1;
        let checkpoint = self.checkpoints[slot];
        if target < self.applied || checkpoint.applied > self.applied {
            let size = SCREEN_PIXELS / 2;
            let packed = &self.screens[slot * size..(slot + 1) * size];
            self.state.restore(&checkpoint.small, packed);
            self.applied = checkpoint.applied;
            dirty = [0, 0, SCREEN_WIDTH as u16, SCREEN_HEIGHT as u16];
        }
        let start = self.applied as usize * PACK_SIZE;
        let end = target as usize * PACK_SIZE;
        for pack in self.packs[start..end].chunks_exact(PACK_SIZE) {
            self.state.apply(pack, &mut dirty);
        }
        self.applied = target;
        self.dirty = dirty;
        let after = self.state.small();
        let mut changes = if dirty[2] > dirty[0] {
            CHANGED_SCREEN
        } else {
            0
        };
        if after.palette != before.palette {
            changes |= CHANGED_PALETTE;
        }
        if after.transparent != before.transparent {
            changes |= CHANGED_TRANSPARENCY;
        }
        if after.h_offset != before.h_offset || after.v_offset != before.v_offset {
            changes |= CHANGED_SCROLL;
        }
        if after.preset != before.preset || after.border != before.border {
            changes |= CHANGED_PRESETS;
        }
        self.changes = changes;
    }

    /// The decoder state at the current position.
    pub fn state(&self) -> &State {
        &self.state
    }

    /// Screen rectangle `[x0, y0, x1, y1)` covering every pixel the last advance may have
    /// changed; empty (`x0 == x1`) when it changed none. A restored checkpoint covers the screen.
    pub fn dirty(&self) -> [u16; 4] {
        self.dirty
    }

    /// `CHANGED_*` bits describing the last advance.
    pub fn changes(&self) -> u32 {
        self.changes
    }

    /// Writes the visible 288 x 192 window as straight-alpha RGBA8, rows top to bottom, into
    /// `out` ([`WINDOW_RGBA_BYTES`] long). Each 4-bit channel `c` becomes `c * 17`; `key`
    /// chooses the alpha. A refusal leaves `out` unchanged.
    pub fn window_rgba(&self, key: Key, out: &mut [u8]) -> Result<(), CdgError> {
        if out.len() != WINDOW_RGBA_BYTES {
            return Err(CdgError::Length);
        }
        let s = &self.state;
        let mut lut = [[0u8; 4]; 16];
        for (i, entry) in lut.iter_mut().enumerate() {
            let rgb = s.palette[i];
            let alpha = match key {
                Key::None => 255,
                Key::TransparentTable => (((63 - s.transparent[i] as u32) * 255 + 31) / 63) as u8,
                Key::PresetColour => {
                    if i as u8 == s.preset {
                        0
                    } else {
                        255
                    }
                }
                Key::Index(k) if k > 15 => return Err(CdgError::KeyIndex),
                Key::Index(k) => {
                    if i as u8 == k {
                        0
                    } else {
                        255
                    }
                }
                Key::Mask(m) => {
                    if (m >> i) & 1 == 1 {
                        0
                    } else {
                        255
                    }
                }
            };
            *entry = [
                ((rgb >> 8) & 0xF) as u8 * 17,
                ((rgb >> 4) & 0xF) as u8 * 17,
                (rgb & 0xF) as u8 * 17,
                alpha,
            ];
        }
        let (x0, y0) = s.window_origin();
        for (row, line) in out.chunks_exact_mut(WINDOW_WIDTH * 4).enumerate() {
            let at = (y0 + row) * SCREEN_WIDTH + x0;
            let src = &s.screen[at..at + WINDOW_WIDTH];
            for (px, &index) in line.chunks_exact_mut(4).zip(src) {
                px.copy_from_slice(&lut[index as usize]);
            }
        }
        Ok(())
    }

    /// Writes into `out[i]` how many pixels of `region` in the visible window hold colour index
    /// `i`, so a host can choose a key from the window's dominant background. Never allocates.
    pub fn index_counts(&self, region: Region, out: &mut [u32; 16]) {
        *out = [0; 16];
        let s = &self.state;
        let (x0, y0) = s.window_origin();
        for row in 0..WINDOW_HEIGHT {
            let at = (y0 + row) * SCREEN_WIDTH + x0;
            let line = &s.screen[at..at + WINDOW_WIDTH];
            let ring = !(TILE_HEIGHT..WINDOW_HEIGHT - TILE_HEIGHT).contains(&row);
            if region == Region::Window || ring {
                for &index in line {
                    out[index as usize] += 1;
                }
            } else {
                for &index in line[..TILE_WIDTH]
                    .iter()
                    .chain(&line[WINDOW_WIDTH - TILE_WIDTH..])
                {
                    out[index as usize] += 1;
                }
            }
        }
    }
}

fn push_checkpoint(checkpoints: &mut Vec<Checkpoint>, screens: &mut Vec<u8>, s: &State, at: u64) {
    checkpoints.push(Checkpoint {
        applied: at,
        small: s.small(),
    });
    for pair in s.screen.chunks_exact(2) {
        screens.push(pair[0] | (pair[1] << 4));
    }
}
