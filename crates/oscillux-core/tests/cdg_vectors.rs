// SPDX-License-Identifier: AGPL-3.0-only
//! Runs every stream in `conformance/cdg/` through the CD+G decoder, sequentially and by
//! seeking in shuffled order, and requires every expected line to match exactly.

use oscillux_core::cdg::{
    Decoder, Key, Region, CHANGED_PALETTE, CHANGED_SCREEN, CHANGED_SCROLL, PACK_SIZE, SCREEN_WIDTH,
    WINDOW_RGBA_BYTES,
};

const STREAMS: [(&str, &[u8], &str); 10] = [
    (
        "presets",
        include_bytes!("../../../conformance/cdg/presets.cdg"),
        include_str!("../../../conformance/cdg/presets.expect"),
    ),
    (
        "tiles",
        include_bytes!("../../../conformance/cdg/tiles.cdg"),
        include_str!("../../../conformance/cdg/tiles.expect"),
    ),
    (
        "xor",
        include_bytes!("../../../conformance/cdg/xor.cdg"),
        include_str!("../../../conformance/cdg/xor.expect"),
    ),
    (
        "scroll",
        include_bytes!("../../../conformance/cdg/scroll.cdg"),
        include_str!("../../../conformance/cdg/scroll.expect"),
    ),
    (
        "palette",
        include_bytes!("../../../conformance/cdg/palette.cdg"),
        include_str!("../../../conformance/cdg/palette.expect"),
    ),
    (
        "ignored",
        include_bytes!("../../../conformance/cdg/ignored.cdg"),
        include_str!("../../../conformance/cdg/ignored.expect"),
    ),
    (
        "mixed",
        include_bytes!("../../../conformance/cdg/mixed.cdg"),
        include_str!("../../../conformance/cdg/mixed.expect"),
    ),
    (
        "lyrics",
        include_bytes!("../../../conformance/cdg/lyrics.cdg"),
        include_str!("../../../conformance/cdg/lyrics.expect"),
    ),
    (
        "karaoke-blue",
        include_bytes!("../../../conformance/cdg/karaoke-blue.cdg"),
        include_str!("../../../conformance/cdg/karaoke-blue.expect"),
    ),
    (
        "karaoke-tiles",
        include_bytes!("../../../conformance/cdg/karaoke-tiles.cdg"),
        include_str!("../../../conformance/cdg/karaoke-tiles.expect"),
    ),
];
const LONG_EXPECT: &str = include_str!("../../../conformance/cdg/long-5min.expect");
const LONG_SEED: u64 = 0x5EED0300;
const LONG_PACKS: usize = 90000;
const MIXED_SEED: u64 = 0x5EED0001;

/// The README's LCG stream (input generation only; expected values come from the oracle).
fn lcg_stream(seed: u64, count: usize) -> Vec<u8> {
    let mut s = seed;
    let mut next = move || {
        s = s
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (s >> 32) as u32
    };
    const KNOWN: [u8; 9] = [1, 2, 6, 38, 20, 24, 28, 30, 31];
    const TABLE: [(u32, u8); 10] = [
        (800, 6),
        (900, 38),
        (930, 30),
        (960, 31),
        (970, 28),
        (980, 24),
        (988, 20),
        (993, 1),
        (997, 2),
        (1000, 0xFF),
    ];
    let mut out = Vec::with_capacity(count * PACK_SIZE);
    for _ in 0..count {
        let mut p = [0u8; PACK_SIZE];
        for b in p.iter_mut() {
            *b = (next() & 0xFF) as u8;
        }
        let sel = next() % 1000;
        if sel < 500 {
            let cmd = (next() & 0x3F) as u8;
            p[0] = (p[0] & 0xC0) | if cmd == 9 { 0 } else { cmd };
        } else {
            p[0] = (p[0] & 0xC0) | 9;
            let mut kind = TABLE.iter().find(|(limit, _)| sel < *limit).unwrap().1;
            if kind == 0xFF {
                let ins = (next() & 0x3F) as u8;
                kind = if KNOWN.contains(&ins) { 0 } else { ins };
            }
            p[1] = (p[1] & 0xC0) | kind;
        }
        out.extend_from_slice(&p);
    }
    out
}

/// SHA-256 (FIPS 180-4), hex.
fn sha256(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for block in msg.chunks_exact(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(block[4 * i..4 * i + 4].try_into().unwrap());
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (x, y) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *x = x.wrapping_add(y);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

fn state_line(d: &Decoder) -> String {
    let s = d.state();
    let palette: String = s.palette.iter().map(|c| format!("{c:03x}")).collect();
    let transparent: String = s.transparent.iter().map(|t| format!("{t:02x}")).collect();
    format!(
        "state {} {} {} {} {} {} {} {}",
        d.applied(),
        sha256(&s.screen),
        palette,
        transparent,
        s.h_offset,
        s.v_offset,
        s.preset,
        s.border
    )
}

fn rgba_line(d: &Decoder, key: &str, out: &mut [u8]) -> String {
    let parsed = match key {
        "none" => Key::None,
        "table" => Key::TransparentTable,
        "preset" => Key::PresetColour,
        other => match other.strip_prefix("mask:") {
            Some(mask) => Key::Mask(u16::from_str_radix(mask, 16).unwrap()),
            None => Key::Index(other.strip_prefix("index:").unwrap().parse().unwrap()),
        },
    };
    d.window_rgba(parsed, out).unwrap();
    format!("rgba {} {} {}", d.applied(), key, sha256(out))
}

fn counts_line(d: &Decoder, region: &str) -> String {
    let mut counts = [0u32; 16];
    let parsed = match region {
        "window" => Region::Window,
        _ => Region::Edge,
    };
    d.index_counts(parsed, &mut counts);
    let joined: Vec<String> = counts.iter().map(u32::to_string).collect();
    format!("counts {} {} {}", d.applied(), region, joined.join(","))
}

/// Expected lines grouped by position, in file order.
fn samples(expect: &str) -> Vec<(u64, Vec<&str>)> {
    let mut out: Vec<(u64, Vec<&str>)> = Vec::new();
    for line in expect.lines().filter(|l| !l.starts_with('#')) {
        let applied: u64 = line.split(' ').nth(1).unwrap().parse().unwrap();
        match out.last_mut() {
            Some((at, lines)) if *at == applied => lines.push(line),
            _ => out.push((applied, vec![line])),
        }
    }
    out
}

fn check_sample(name: &str, d: &Decoder, lines: &[&str], rgba: &mut [u8]) {
    for want in lines {
        let got = if want.starts_with("state ") {
            state_line(d)
        } else if want.starts_with("counts ") {
            counts_line(d, want.split(' ').nth(2).unwrap())
        } else {
            let key = want.split(' ').nth(2).unwrap();
            rgba_line(d, key, rgba)
        };
        assert_eq!(&got, want, "{name}");
    }
}

fn run(name: &str, stream: &[u8], expect: &str) -> usize {
    let groups = samples(expect);
    let mut rgba = vec![0u8; WINDOW_RGBA_BYTES];
    // Sequential: advance from sample to sample.
    let mut d = Decoder::new(stream);
    for (applied, lines) in &groups {
        d.advance_to(*applied);
        assert_eq!(d.applied(), *applied, "{name}");
        check_sample(name, &d, lines, &mut rgba);
    }
    // Seeking: visit the samples in a fixed shuffled order (forward and backward jumps).
    let mut order: Vec<usize> = (0..groups.len()).collect();
    let mut s = 0x9E3779B97F4A7C15u64 ^ groups.len() as u64;
    for i in (1..order.len()).rev() {
        s = s
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        order.swap(i, ((s >> 33) % (i as u64 + 1)) as usize);
    }
    for &i in &order {
        let (applied, lines) = &groups[i];
        d.advance_to(*applied);
        check_sample(name, &d, lines, &mut rgba);
    }
    groups.iter().map(|(_, l)| l.len()).sum()
}

#[test]
fn committed_streams_match_the_oracle() {
    for (name, stream, expect) in STREAMS {
        let lines = run(name, stream, expect);
        assert!(lines > 10, "{name}: {lines} lines");
    }
}

#[test]
fn mixed_stream_is_the_readme_lcg() {
    assert_eq!(lcg_stream(MIXED_SEED, 3000), STREAMS[6].1);
}

#[test]
fn five_minute_stream_seeks_match_the_oracle() {
    let stream = lcg_stream(LONG_SEED, LONG_PACKS);
    let lines = run("long-5min", &stream, LONG_EXPECT);
    assert!(lines > 90, "{lines} lines");
}

#[test]
fn media_time_maps_to_floor_times_300() {
    let d = Decoder::new(STREAMS[6].1);
    assert_eq!(d.position_for_time(-1.0), Ok(0));
    assert_eq!(d.position_for_time(0.0), Ok(1));
    assert_eq!(d.position_for_time(1.0 / 300.0 - 1e-9), Ok(1));
    assert_eq!(d.position_for_time(2.0), Ok(601));
    assert_eq!(d.position_for_time(2.0 + 0.5 / 300.0), Ok(601));
    assert_eq!(d.position_for_time(1e300), Ok(3000));
    assert_eq!(d.position_for_time(f64::INFINITY), Ok(3000));
    assert!(d.position_for_time(f64::NAN).is_err());
}

#[test]
fn partial_trailing_pack_is_ignored() {
    let mut stream = STREAMS[1].1.to_vec();
    let whole = Decoder::new(&stream).pack_count();
    stream.extend_from_slice(&[9, 1, 0, 0, 5]);
    let mut d = Decoder::new(&stream);
    assert_eq!(d.pack_count(), whole);
    d.advance_to(u64::MAX);
    assert_eq!(d.applied(), whole);
}

/// Pixels outside the reported dirty rectangle never change in an advance, and the change bits
/// report palette and scroll changes.
#[test]
fn dirty_rectangle_covers_every_change() {
    let stream = STREAMS[6].1;
    let mut d = Decoder::new(stream);
    let mut previous = d.state().screen.to_vec();
    let mut screen_changes = 0;
    let mut position = 0u64;
    let mut step = 1u64;
    while position < d.pack_count() {
        let palette = d.state().palette;
        let offsets = (d.state().h_offset, d.state().v_offset);
        position += step;
        step = step % 7 + 1;
        d.advance_to(position);
        let [x0, y0, x1, y1] = d.dirty().map(|v| v as usize);
        for (i, (&now, &was)) in d.state().screen.iter().zip(&previous).enumerate() {
            let (x, y) = (i % SCREEN_WIDTH, i / SCREEN_WIDTH);
            let inside = x >= x0 && x < x1 && y >= y0 && y < y1;
            assert!(
                inside || now == was,
                "pixel {x},{y} changed outside the dirty rect"
            );
        }
        if d.changes() & CHANGED_SCREEN != 0 {
            screen_changes += 1;
        }
        assert_eq!(
            d.changes() & CHANGED_PALETTE != 0,
            palette != d.state().palette
        );
        let moved = offsets != (d.state().h_offset, d.state().v_offset);
        assert_eq!(d.changes() & CHANGED_SCROLL != 0, moved);
        previous.copy_from_slice(&d.state().screen);
    }
    assert!(screen_changes > 100);
}

#[test]
fn key_index_above_15_is_refused_without_writing() {
    let d = Decoder::new(STREAMS[0].1);
    let mut out = vec![7u8; WINDOW_RGBA_BYTES];
    assert!(d.window_rgba(Key::Index(16), &mut out).is_err());
    assert!(out.iter().all(|&b| b == 7));
    assert!(d.window_rgba(Key::None, &mut out[1..]).is_err());
}
