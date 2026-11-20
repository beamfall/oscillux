// SPDX-License-Identifier: AGPL-3.0-only
//! Oscillux core: audio analysis, flash limiting, uniform packing and transition math.
#![cfg_attr(not(test), no_std)]
#![warn(missing_docs)]

extern crate alloc;

pub mod beatgrid;
pub mod dsp;
pub mod limiter;

/// Crate version, for hosts that log which core they loaded.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub mod curves;
pub mod governor;
pub mod mapping;
pub mod overlay;
pub mod packing;
pub mod palette;
pub mod reaction;
pub mod transition;
pub mod window_governor;

// CD+G lyric graphics decoder (OSC-CDG).
pub mod cdg;
