// SPDX-License-Identifier: AGPL-3.0-only
//! Replays `conformance/cdg-present/*.expect` (written by `tools/cdg-present-vectors.py`, an
//! independent model of that directory's README) through `oscillux_core::cdg::present`, and
//! checks the presenter's easing and allocation-free behaviour.

use oscillux_core::cdg::present::{backdrop_indices, background_index, Presenter, EASE_MS};
use oscillux_core::cdg::Decoder;

const STREAMS: [(&str, &[u8], &str); 4] = [
    (
        "karaoke-blue",
        include_bytes!("../../../conformance/cdg/karaoke-blue.cdg"),
        include_str!("../../../conformance/cdg-present/karaoke-blue.expect"),
    ),
    (
        "karaoke-tiles",
        include_bytes!("../../../conformance/cdg/karaoke-tiles.cdg"),
        include_str!("../../../conformance/cdg-present/karaoke-tiles.expect"),
    ),
    (
        "presets",
        include_bytes!("../../../conformance/cdg/presets.cdg"),
        include_str!("../../../conformance/cdg-present/presets.expect"),
    ),
    (
        "scroll",
        include_bytes!("../../../conformance/cdg/scroll.cdg"),
        include_str!("../../../conformance/cdg-present/scroll.expect"),
    ),
];

fn number<T: std::str::FromStr>(field: Option<&str>, line: &str) -> T {
    field
        .and_then(|f| f.parse().ok())
        .unwrap_or_else(|| panic!("malformed line: {line}"))
}

#[test]
fn presenter_matches_vectors() {
    for (name, stream, expect) in STREAMS {
        let mut bg_decoder = Decoder::new(stream);
        let mut sized: Option<(Decoder, Presenter)> = None;
        let mut frames = 0;
        for line in expect.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut f = line.split_whitespace();
            match f.next() {
                Some("bg") => {
                    let packs: u64 = number(f.next(), line);
                    let index: u8 = number(f.next(), line);
                    let mask = u16::from_str_radix(f.next().unwrap_or(""), 16)
                        .unwrap_or_else(|_| panic!("malformed line: {line}"));
                    bg_decoder.advance_to(packs);
                    assert_eq!(background_index(&bg_decoder), index, "{name}: {line}");
                    let set = backdrop_indices(&bg_decoder);
                    let got = (0..16).filter(|&i| set[i]).fold(0u16, |m, i| m | 1 << i);
                    assert_eq!(got, mask, "{name}: {line}");
                }
                Some("size") => {
                    let w: usize = number(f.next(), line);
                    let h: usize = number(f.next(), line);
                    let presenter = Presenter::new(w, h).expect("valid size");
                    sized = Some((Decoder::new(stream), presenter));
                }
                Some("frame") => {
                    let (decoder, presenter) = sized.as_mut().expect("frame before size");
                    let packs: u64 = number(f.next(), line);
                    let millis: i64 = number(f.next(), line);
                    decoder.advance_to(packs);
                    let digest = sha256(presenter.present(decoder, millis));
                    assert_eq!(Some(digest.as_str()), f.next(), "{name}: {line}");
                    frames += 1;
                }
                _ => panic!("{name}: unknown line: {line}"),
            }
        }
        assert!(frames > 0, "{name}: no frames");
    }
}

#[test]
fn rejects_out_of_range_sizes() {
    assert!(Presenter::new(0, 10).is_none());
    assert!(Presenter::new(10, 0).is_none());
    assert!(Presenter::new(8193, 10).is_none());
    assert!(Presenter::new(1, 1).is_some());
}

#[test]
fn stage_eases_after_a_colour_change_and_snaps_on_seek() {
    let (_, stream, _) = STREAMS[2];
    let mut decoder = Decoder::new(stream);
    let packs = stream.len() as u64 / 24;
    let mut presenter = Presenter::new(32, 18).unwrap();
    // Find the first position where the background colour changes.
    let mut previous = None;
    let mut change = None;
    for p in 0..=packs {
        decoder.advance_to(p);
        let s = decoder.state();
        let colour = s.palette[background_index(&decoder) as usize];
        if previous.is_some_and(|c| c != colour) {
            change = Some(p);
            break;
        }
        previous = Some(colour);
    }
    let change = change.expect("presets stream changes background");
    decoder.advance_to(change - 1);
    presenter.present(&decoder, 0);
    let before = presenter.stage_colour();
    decoder.advance_to(change);
    presenter.present(&decoder, 1000);
    assert_eq!(
        presenter.stage_colour(),
        before,
        "change frame starts from the old colour"
    );
    presenter.present(&decoder, 1000 + EASE_MS / 2);
    let middle = presenter.stage_colour();
    presenter.present(&decoder, 1000 + EASE_MS);
    let after = presenter.stage_colour();
    assert_ne!(middle, before);
    assert_ne!(middle, after);
    presenter.present(&decoder, 1000 + EASE_MS * 5);
    assert_eq!(presenter.stage_colour(), after, "target reached at EASE_MS");
    // A backwards seek snaps straight to the colour there.
    decoder.advance_to(change - 1);
    presenter.present(&decoder, 10);
    assert_eq!(presenter.stage_colour(), before);
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

/// One TV-graphics pack: `instruction` and 16 data bytes.
fn pack(instruction: u8, data: [u8; 16]) -> [u8; 24] {
    let mut p = [0u8; 24];
    p[0] = 0x09;
    p[1] = instruction;
    p[4..20].copy_from_slice(&data);
    p
}

/// Load Colour Table (low) with `colours` (12-bit `0xRGB`) as indices 0..=7.
fn load_colours(colours: [u16; 8]) -> [u8; 24] {
    let mut data = [0u8; 16];
    for (i, c) in colours.iter().enumerate() {
        let (r, g, b) = ((c >> 8) & 15, (c >> 4) & 15, c & 15);
        data[2 * i] = ((r << 2) | (g >> 2)) as u8;
        data[2 * i + 1] = (((g & 3) << 4) | b) as u8;
    }
    pack(30, data)
}

#[test]
fn outline_protection_resets_when_the_palette_changes() {
    // Dark blue (index 1) on a black stage, outlined in white (index 2) on three sides: the
    // outline protects the blue from the contrast fix. Then the outline turns near black and
    // no longer contrasts, so the blue must be fixed exactly as a fresh presenter fixes it.
    let mut tile = [0u8; 16];
    tile[0] = 2;
    tile[1] = 1;
    tile[2] = 8;
    tile[3] = 25;
    for row in &mut tile[5..15] {
        *row = 0b01_1111;
    }
    let mut stream = Vec::new();
    stream.extend(load_colours([0x000, 0x004, 0xfff, 0, 0, 0, 0, 0]));
    stream.extend(pack(1, [0; 16]));
    stream.extend(pack(6, tile));
    stream.extend(load_colours([0x000, 0x004, 0x002, 0, 0, 0, 0, 0]));
    let mut decoder = Decoder::new(&stream);

    let raw_blue = |frame: &[u8]| frame.chunks_exact(4).any(|px| px == [0, 0, 68, 255]);
    let mut outlined = Presenter::new(160, 90).unwrap();
    decoder.advance_to(3);
    assert!(
        raw_blue(outlined.present(&decoder, 0)),
        "outlined blue keeps its colour"
    );

    decoder.advance_to(4);
    let after = outlined.present(&decoder, 100).to_vec();
    assert!(!raw_blue(&after), "unoutlined blue is lightened");
    let mut fresh = Presenter::new(160, 90).unwrap();
    assert_eq!(after, fresh.present(&decoder, 100));
}
