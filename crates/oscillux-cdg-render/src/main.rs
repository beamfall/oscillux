// SPDX-License-Identifier: AGPL-3.0-only
//! `oscillux-cdg-render`: reads a CD+G stream on stdin and writes raw RGBA8 frames to stdout.
//!
//! ```text
//! oscillux-cdg-render --width W --height H [--fps 30] [--start 0] [--tempo 1] [--frames N]
//! ```
//!
//! Frame `n` shows source time `start + n / fps * tempo` seconds, drawn by
//! `oscillux_core::cdg::present::Presenter`. Time stops [`EASE_MS`] after the first frame that
//! shows the stream's last pack, so the picture holds once the stream ends. With `--frames N` it writes N frames and exits 1 if
//! a write fails first; without it, it writes until a write fails (the reader closed the pipe),
//! then exits 0.
//! Built for `wasm32-wasip1` so a host can run it in a WebAssembly runtime with no file access.

use std::io::{self, Read, Write};
use std::process::ExitCode;

use oscillux_core::cdg::present::{Presenter, EASE_MS, MAX_DIMENSION};
use oscillux_core::cdg::{Decoder, PACKS_PER_SECOND};

struct Options {
    width: usize,
    height: usize,
    fps: f64,
    start: f64,
    tempo: f64,
    frames: Option<u64>,
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut o = Options {
        width: 0,
        height: 0,
        fps: 30.0,
        start: 0.0,
        tempo: 1.0,
        frames: None,
    };
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let value = it.next().ok_or_else(|| format!("{flag} needs a value"))?;
        let bad = || format!("bad value for {flag}: {value}");
        match flag.as_str() {
            "--width" => o.width = value.parse().map_err(|_| bad())?,
            "--height" => o.height = value.parse().map_err(|_| bad())?,
            "--fps" => o.fps = value.parse().map_err(|_| bad())?,
            "--start" => o.start = value.parse().map_err(|_| bad())?,
            "--tempo" => o.tempo = value.parse().map_err(|_| bad())?,
            "--frames" => o.frames = Some(value.parse().map_err(|_| bad())?),
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    let size = 1..=MAX_DIMENSION;
    if !size.contains(&o.width) || !size.contains(&o.height) {
        return Err(format!("--width and --height must be 1..={MAX_DIMENSION}"));
    }
    if !(o.fps.is_finite() && o.fps > 0.0 && o.fps <= 240.0) {
        return Err("--fps must be in (0, 240]".into());
    }
    if !(o.tempo.is_finite() && o.tempo > 0.0 && o.tempo <= 4.0) {
        return Err("--tempo must be in (0, 4]".into());
    }
    if !o.start.is_finite() {
        return Err("--start must be finite".into());
    }
    Ok(o)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let o = match parse(&args) {
        Ok(o) => o,
        Err(message) => {
            eprintln!("oscillux-cdg-render: {message}");
            return ExitCode::from(2);
        }
    };
    if o.frames == Some(0) {
        return ExitCode::SUCCESS;
    }
    let mut stream = Vec::new();
    if let Err(error) = io::stdin().lock().read_to_end(&mut stream) {
        eprintln!("oscillux-cdg-render: reading stdin: {error}");
        return ExitCode::from(1);
    }
    let mut decoder = Decoder::new(&stream);
    drop(stream);
    let mut presenter = Presenter::new(o.width, o.height).expect("dimensions checked");
    let mut out = io::stdout().lock();
    // Once the last pack is on screen, time runs on for the stage easing, then stops.
    let mut hold: Option<i64> = None;
    let mut n: u64 = 0;
    while o.frames.is_none_or(|limit| n < limit) {
        let seconds = o.start + n as f64 * o.tempo / o.fps;
        let mut millis = floor_units(seconds, 1000);
        if let Some(stop) = hold {
            millis = millis.min(stop);
        } else {
            decoder.advance_to(
                floor_units(seconds, PACKS_PER_SECOND)
                    .saturating_add(1)
                    .max(0) as u64,
            );
            if decoder.applied() == decoder.pack_count() {
                hold = Some(millis.saturating_add(EASE_MS));
            }
        }
        let written = out.write_all(presenter.present(&decoder, millis));
        if written.is_err() {
            // Unbounded: the reader closed the pipe, so it has every frame it wants.
            return failure(o.frames.is_some(), "writing stdout");
        }
        n += 1;
    }
    match out.flush() {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => failure(o.frames.is_some(), "flushing stdout"),
    }
}

/// `floor(seconds * per_second + 1e-6)`: a time less than a millionth of a unit below a pack or
/// millisecond boundary counts as on it, so floating-point rounding never shows a pack late.
fn floor_units(seconds: f64, per_second: u32) -> i64 {
    (seconds * per_second as f64 + 1e-6).floor() as i64
}

fn failure(bounded: bool, what: &str) -> ExitCode {
    if bounded {
        eprintln!("oscillux-cdg-render: {what} failed before every frame was written");
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}
