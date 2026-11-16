// SPDX-License-Identifier: AGPL-3.0-only
//! The decoder state and the TV-graphics instructions that change it.

use super::{
    BORDER_X, BORDER_Y, COMMAND_TV_GRAPHICS, FULL_SCREEN_COST, INSTRUCTION_BORDER_PRESET,
    INSTRUCTION_DEFINE_TRANSPARENT, INSTRUCTION_LOAD_COLOURS_HIGH, INSTRUCTION_LOAD_COLOURS_LOW,
    INSTRUCTION_MEMORY_PRESET, INSTRUCTION_SCROLL_COPY, INSTRUCTION_SCROLL_PRESET,
    INSTRUCTION_TILE_NORMAL, INSTRUCTION_TILE_XOR, SCREEN_HEIGHT, SCREEN_PIXELS, SCREEN_WIDTH,
    TILE_HEIGHT, TILE_WIDTH, WINDOW_HEIGHT, WINDOW_WIDTH,
};
use alloc::boxed::Box;

/// Everything but the screen; small enough to copy per checkpoint and per advance.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) struct Small {
    pub(super) palette: [u16; 16],
    pub(super) transparent: [u8; 16],
    pub(super) h_offset: u8,
    pub(super) v_offset: u8,
    pub(super) preset: u8,
    pub(super) border: u8,
}

/// Decoder state at one position. Every field starts at zero.
pub struct State {
    /// Colour index (0..=15) of every screen pixel, rows top to bottom.
    pub screen: Box<[u8]>,
    /// Colour table as `0xRGB`, 4 bits per channel.
    pub palette: [u16; 16],
    /// Transparent-colour table: the 6-bit value Define Transparent Colour gave each index.
    pub transparent: [u8; 16],
    /// Horizontal scroll offset, 0..=5 pixels.
    pub h_offset: u8,
    /// Vertical scroll offset, 0..=11 pixels.
    pub v_offset: u8,
    /// Colour of the most recent Memory Preset.
    pub preset: u8,
    /// Colour of the most recent Border Preset.
    pub border: u8,
}

impl Default for State {
    fn default() -> Self {
        Self::new()
    }
}

impl State {
    /// The state before any pack: every index, colour and offset zero.
    pub fn new() -> Self {
        State {
            screen: alloc::vec![0u8; SCREEN_PIXELS].into_boxed_slice(),
            palette: [0; 16],
            transparent: [0; 16],
            h_offset: 0,
            v_offset: 0,
            preset: 0,
            border: 0,
        }
    }

    /// Top-left screen pixel of the visible window: the border shifted by the scroll offsets.
    pub fn window_origin(&self) -> (usize, usize) {
        (
            BORDER_X + self.h_offset as usize,
            BORDER_Y + self.v_offset as usize,
        )
    }

    pub(super) fn reset(&mut self) {
        self.screen.fill(0);
        self.restore_small(&Small {
            palette: [0; 16],
            transparent: [0; 16],
            h_offset: 0,
            v_offset: 0,
            preset: 0,
            border: 0,
        });
    }

    pub(super) fn small(&self) -> Small {
        Small {
            palette: self.palette,
            transparent: self.transparent,
            h_offset: self.h_offset,
            v_offset: self.v_offset,
            preset: self.preset,
            border: self.border,
        }
    }

    fn restore_small(&mut self, s: &Small) {
        self.palette = s.palette;
        self.transparent = s.transparent;
        self.h_offset = s.h_offset;
        self.v_offset = s.v_offset;
        self.preset = s.preset;
        self.border = s.border;
    }

    /// Restores a checkpoint: `packed` holds two pixels per byte, low nibble first.
    pub(super) fn restore(&mut self, small: &Small, packed: &[u8]) {
        self.restore_small(small);
        for (pair, &byte) in self.screen.chunks_exact_mut(2).zip(packed) {
            pair[0] = byte & 0xF;
            pair[1] = byte >> 4;
        }
    }

    /// Decodes one 24-byte pack, grows `dirty` (`[x0, y0, x1, y1)`, empty when `x0 == x1`) over
    /// the pixels it may change and returns its replay cost (0 for an ignored pack).
    pub(super) fn apply(&mut self, pack: &[u8], dirty: &mut [u16; 4]) -> u32 {
        if pack[0] & 0x3F != COMMAND_TV_GRAPHICS {
            return 0;
        }
        let mut data = [0u8; 16];
        for (d, &b) in data.iter_mut().zip(&pack[4..20]) {
            *d = b & 0x3F;
        }
        match pack[1] & 0x3F {
            INSTRUCTION_MEMORY_PRESET => {
                // The repeat count (data[1]) only marks retransmissions; every copy is applied,
                // which is idempotent and survives a lost first copy.
                let colour = data[0] & 0x0F;
                self.screen.fill(colour);
                self.preset = colour;
                grow(dirty, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
                FULL_SCREEN_COST
            }
            INSTRUCTION_BORDER_PRESET => {
                let colour = data[0] & 0x0F;
                self.border = colour;
                let right = BORDER_X + WINDOW_WIDTH;
                let bottom = BORDER_Y + WINDOW_HEIGHT;
                for (y, row) in self.screen.chunks_exact_mut(SCREEN_WIDTH).enumerate() {
                    if y < BORDER_Y || y >= bottom {
                        row.fill(colour);
                    } else {
                        row[..BORDER_X].fill(colour);
                        row[right..].fill(colour);
                    }
                }
                grow(dirty, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
                FULL_SCREEN_COST / 4
            }
            op @ (INSTRUCTION_TILE_NORMAL | INSTRUCTION_TILE_XOR) => {
                let colours = [data[0] & 0x0F, data[1] & 0x0F];
                let row = (data[2] & 0x1F) as usize;
                let column = (data[3] & 0x3F) as usize;
                if row >= SCREEN_HEIGHT / TILE_HEIGHT || column >= SCREEN_WIDTH / TILE_WIDTH {
                    return 1;
                }
                let (x, y) = (column * TILE_WIDTH, row * TILE_HEIGHT);
                for (r, &bits) in data[4..16].iter().enumerate() {
                    let at = (y + r) * SCREEN_WIDTH + x;
                    let line = &mut self.screen[at..at + TILE_WIDTH];
                    for (c, px) in line.iter_mut().enumerate() {
                        let colour = colours[((bits >> (5 - c)) & 1) as usize];
                        if op == INSTRUCTION_TILE_XOR {
                            *px ^= colour;
                        } else {
                            *px = colour;
                        }
                    }
                }
                grow(dirty, x, y, x + TILE_WIDTH, y + TILE_HEIGHT);
                1
            }
            op @ (INSTRUCTION_SCROLL_PRESET | INSTRUCTION_SCROLL_COPY) => {
                let fill = if op == INSTRUCTION_SCROLL_PRESET {
                    Some(data[0] & 0x0F)
                } else {
                    None
                };
                self.scroll(fill, (data[1] >> 4) & 3, (data[2] >> 4) & 3);
                self.h_offset = (data[1] & 0x07).min(5);
                self.v_offset = (data[2] & 0x0F).min(11);
                grow(dirty, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
                FULL_SCREEN_COST
            }
            INSTRUCTION_DEFINE_TRANSPARENT => {
                self.transparent = data;
                1
            }
            op @ (INSTRUCTION_LOAD_COLOURS_LOW | INSTRUCTION_LOAD_COLOURS_HIGH) => {
                let base = if op == INSTRUCTION_LOAD_COLOURS_LOW {
                    0
                } else {
                    8
                };
                for (i, pair) in data.chunks_exact(2).enumerate() {
                    let (hi, lo) = (pair[0] as u16, pair[1] as u16);
                    let r = (hi >> 2) & 0xF;
                    let g = ((hi & 3) << 2) | ((lo >> 4) & 3);
                    let b = lo & 0xF;
                    self.palette[base + i] = (r << 8) | (g << 4) | b;
                }
                1
            }
            _ => 0,
        }
    }

    /// Scrolls the whole screen: `h` 1 moves it 6 pixels right, 2 left; `v` 1 moves it 12 pixels
    /// down, 2 up; 0 and 3 do not move. `fill` is the Scroll Preset colour for the vacated strip;
    /// without it (Scroll Copy) the screen wraps around.
    fn scroll(&mut self, fill: Option<u8>, h: u8, v: u8) {
        if h == 1 || h == 2 {
            for row in self.screen.chunks_exact_mut(SCREEN_WIDTH) {
                if h == 1 {
                    row.rotate_right(TILE_WIDTH);
                    if let Some(colour) = fill {
                        row[..TILE_WIDTH].fill(colour);
                    }
                } else {
                    row.rotate_left(TILE_WIDTH);
                    if let Some(colour) = fill {
                        row[SCREEN_WIDTH - TILE_WIDTH..].fill(colour);
                    }
                }
            }
        }
        let strip = TILE_HEIGHT * SCREEN_WIDTH;
        if v == 1 {
            self.screen.rotate_right(strip);
            if let Some(colour) = fill {
                self.screen[..strip].fill(colour);
            }
        } else if v == 2 {
            self.screen.rotate_left(strip);
            if let Some(colour) = fill {
                self.screen[SCREEN_PIXELS - strip..].fill(colour);
            }
        }
    }
}

fn grow(dirty: &mut [u16; 4], x0: usize, y0: usize, x1: usize, y1: usize) {
    let (x0, y0, x1, y1) = (x0 as u16, y0 as u16, x1 as u16, y1 as u16);
    if dirty[2] <= dirty[0] {
        *dirty = [x0, y0, x1, y1];
    } else {
        *dirty = [
            dirty[0].min(x0),
            dirty[1].min(y0),
            dirty[2].max(x1),
            dirty[3].max(y1),
        ];
    }
}
