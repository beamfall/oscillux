// SPDX-License-Identifier: AGPL-3.0-only
//! `oscillux-cdg-render`: reads a CD+G stream on stdin and writes raw RGBA8 or YUV420p frames to stdout.
//!
//! ```text
//! oscillux-cdg-render --width W --height H [--fps 30] [--start 0] [--tempo 1] [--frames N] [--pix-fmt rgba|yuv420p]
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PixFmt {
    Rgba,
    Yuv420p,
}

struct Options {
    width: usize,
    height: usize,
    fps: f64,
    start: f64,
    tempo: f64,
    frames: Option<u64>,
    pix_fmt: PixFmt,
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut o = Options {
        width: 0,
        height: 0,
        fps: 30.0,
        start: 0.0,
        tempo: 1.0,
        frames: None,
        pix_fmt: PixFmt::Rgba,
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
            "--pix-fmt" => {
                o.pix_fmt = match value.as_str() {
                    "rgba" => PixFmt::Rgba,
                    "yuv420p" => PixFmt::Yuv420p,
                    _ => return Err(bad()),
                };
            }
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    let size = 1..=MAX_DIMENSION;
    if !size.contains(&o.width) || !size.contains(&o.height) {
        return Err(format!("--width and --height must be 1..={MAX_DIMENSION}"));
    }
    if o.pix_fmt == PixFmt::Yuv420p && (o.width % 2 != 0 || o.height % 2 != 0) {
        return Err("--width and --height must be even for --pix-fmt yuv420p".into());
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
    let mut yuv = if o.pix_fmt == PixFmt::Yuv420p {
        vec![0u8; o.width * o.height * 3 / 2]
    } else {
        Vec::new()
    };
    let mut rgba_cache = if o.pix_fmt == PixFmt::Rgba {
        vec![0u8; o.width * o.height * 4]
    } else {
        Vec::new()
    };
    let mut out = io::stdout().lock();
    // Once the last pack is on screen, time runs on for the stage easing, then stops.
    let mut hold: Option<i64> = None;
    let mut cached_static = false;
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
        let settled = hold.is_some_and(|stop| millis >= stop);
        let frame_bytes: &[u8] = if cached_static && settled {
            match o.pix_fmt {
                PixFmt::Rgba => &rgba_cache,
                PixFmt::Yuv420p => &yuv,
            }
        } else {
            let rgba = presenter.present(&decoder, millis);
            if settled {
                cached_static = true;
            }
            match o.pix_fmt {
                PixFmt::Rgba => {
                    if settled {
                        rgba_cache.copy_from_slice(rgba);
                        &rgba_cache
                    } else {
                        rgba
                    }
                }
                PixFmt::Yuv420p => {
                    rgba_to_yuv420p(rgba, o.width, o.height, &mut yuv);
                    &yuv
                }
            }
        };
        if out.write_all(frame_bytes).is_err() {
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

/// Converts an RGBA8 buffer (`width * height * 4` bytes, even dimensions) to planar BT.709
/// limited-range YUV420p (`width * height * 3 / 2` bytes) using deterministic integer arithmetic.
fn rgba_to_yuv420p(rgba: &[u8], width: usize, height: usize, yuv: &mut [u8]) {
    let y_len = width * height;
    let uv_len = y_len / 4;
    let (y_plane, uv_planes) = yuv.split_at_mut(y_len);
    let (u_plane, v_plane) = uv_planes.split_at_mut(uv_len);

    for (dst, px) in y_plane.iter_mut().zip(rgba.chunks_exact(4)) {
        let r = px[0] as i32;
        let g = px[1] as i32;
        let b = px[2] as i32;
        *dst = (16 + ((47 * r + 157 * g + 16 * b + 128) >> 8)).clamp(16, 235) as u8;
    }

    let stride = width * 4;
    let half_w = width / 2;
    let half_h = height / 2;
    for cy in 0..half_h {
        let row0 = (cy * 2) * stride;
        let row1 = row0 + stride;
        let out_row = cy * half_w;
        for cx in 0..half_w {
            let x0 = cx * 8;
            let x1 = x0 + 4;
            let r = (rgba[row0 + x0] as i32
                + rgba[row0 + x1] as i32
                + rgba[row1 + x0] as i32
                + rgba[row1 + x1] as i32
                + 2)
                >> 2;
            let g = (rgba[row0 + x0 + 1] as i32
                + rgba[row0 + x1 + 1] as i32
                + rgba[row1 + x0 + 1] as i32
                + rgba[row1 + x1 + 1] as i32
                + 2)
                >> 2;
            let b = (rgba[row0 + x0 + 2] as i32
                + rgba[row0 + x1 + 2] as i32
                + rgba[row1 + x0 + 2] as i32
                + rgba[row1 + x1 + 2] as i32
                + 2)
                >> 2;
            let idx = out_row + cx;
            u_plane[idx] = (128 + ((-26 * r - 87 * g + 112 * b + 128) >> 8)).clamp(16, 240) as u8;
            v_plane[idx] = (128 + ((112 * r - 102 * g - 10 * b + 128) >> 8)).clamp(16, 240) as u8;
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &str) -> String {
        v.to_string()
    }

    #[test]
    fn parse_pix_fmt_and_even_dimension_guard() {
        let opts = parse(&[s("--width"), s("960"), s("--height"), s("540")]).unwrap();
        assert_eq!(opts.pix_fmt, PixFmt::Rgba);

        let yuv = parse(&[
            s("--width"),
            s("960"),
            s("--height"),
            s("540"),
            s("--pix-fmt"),
            s("yuv420p"),
        ])
        .unwrap();
        assert_eq!(yuv.pix_fmt, PixFmt::Yuv420p);

        assert!(parse(&[
            s("--width"),
            s("961"),
            s("--height"),
            s("540"),
            s("--pix-fmt"),
            s("yuv420p"),
        ])
        .is_err());

        assert!(parse(&[
            s("--width"),
            s("960"),
            s("--height"),
            s("540"),
            s("--pix-fmt"),
            s("bgra"),
        ])
        .is_err());
    }

    #[test]
    fn rgba_to_yuv420p_black_white_and_size() {
        let w = 4;
        let h = 2;
        let mut rgba = vec![0u8; w * h * 4];
        for px in rgba.chunks_exact_mut(4) {
            px[3] = 255;
        }
        let mut yuv = vec![0u8; w * h * 3 / 2];
        rgba_to_yuv420p(&rgba, w, h, &mut yuv);
        assert_eq!(yuv.len(), 12);
        assert!(yuv[..8].iter().all(|&y| y == 16));
        assert!(yuv[8..].iter().all(|&uv| uv == 128));

        rgba.fill(255);
        rgba_to_yuv420p(&rgba, w, h, &mut yuv);
        assert!(yuv[..8].iter().all(|&y| y == 235));
        assert!(yuv[8..].iter().all(|&uv| (127..=129).contains(&uv)));
    }

    #[test]
    fn static_frame_matches_fresh_present_after_hold() {
        let w = 16;
        let h = 16;
        let stream = [0u8; 24];
        let decoder = Decoder::new(&stream);
        let mut p1 = Presenter::new(w, h).unwrap();
        let mut p2 = Presenter::new(w, h).unwrap();
        let f_hold1 = p1.present(&decoder, EASE_MS).to_vec();
        let f_hold2 = p2.present(&decoder, EASE_MS).to_vec();
        assert_eq!(f_hold1, f_hold2);

        let mut y1 = vec![0u8; w * h * 3 / 2];
        let mut y2 = vec![0u8; w * h * 3 / 2];
        rgba_to_yuv420p(&f_hold1, w, h, &mut y1);
        rgba_to_yuv420p(&f_hold2, w, h, &mut y2);
        assert_eq!(y1, y2);
    }
}
