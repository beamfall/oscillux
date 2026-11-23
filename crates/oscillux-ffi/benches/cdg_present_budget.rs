// SPDX-License-Identifier: AGPL-3.0-only
//! CPU-time guard for the CD+G presenter (`conformance/cdg-present/README.md`) on its worst case.
//!
//! A host composing live karaoke renders 960x540 frames at 30 fps, so each frame advances the
//! decoder by 10 packs (300 packs per second). The stream here is the presenter's worst case:
//! after a memory preset and a palette of 16 distinct colours, every pack XORs a random 6 x 12
//! tile with random colours somewhere in the visible window, so all 16 indices are inked across
//! the window and every timed pack changes visible pixels (checked before timing). It is
//! generated in code with the `conformance/cdg/README.md` LCG; no recorded stream is checked in.
//!
//! The statistic is thread CPU time (`CLOCK_THREAD_CPUTIME_ID` on 64-bit macOS and Linux), so a
//! busy host's other work is not charged to the presenter. Elsewhere there is no thread CPU
//! clock here: the bench reports wall time and does not enforce the budget. Frames are timed in
//! `ROUNDS` rounds; the gated statistic is the minimum round mean (the mean, since the rare full
//! rebuilds on a background change are part of the sustained cost), so the check fails only
//! when every round is slow.
//!
//! `BUDGET_NS` keeps the WASI renderer at 60 fps or better: under wazero the presenter runs about
//! 2.3x slower than the native release build, so 7 ms native is about 16 ms, one 60 Hz frame.
use oscillux_core::cdg::{
    present::Presenter, Decoder, BORDER_X, BORDER_Y, PACKS_PER_SECOND, SCREEN_WIDTH, WINDOW_HEIGHT,
    WINDOW_WIDTH,
};
use std::{hint::black_box, process::ExitCode};

/// Gated limit on the minimum round mean of native thread CPU time per frame, nanoseconds.
const BUDGET_NS: u64 = 7_000_000;
const WIDTH: usize = 960;
const HEIGHT: usize = 540;
const FPS: u64 = 30;
/// Packs decoded before timing, so the screen is covered in tiles.
const SEED_PACKS: u64 = 3_000;
const WARMUP: u64 = 30;
const ROUNDS: usize = 5;
const FRAMES_PER_ROUND: u64 = 60;

/// The worst-case stream: memory preset, two palette loads, then `tiles` random XOR tiles.
fn worst_stream(tiles: usize) -> Vec<u8> {
    let mut s = 0x5EED_0C06_u64;
    let mut next = move |bound: u32| {
        s = s
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ((s >> 32) as u32) % bound
    };
    let pack = |instruction: u8, data: &[u8]| {
        let mut p = [0u8; 24];
        p[0] = 9;
        p[1] = instruction;
        for (d, &v) in p[4..20].iter_mut().zip(data) {
            *d = v & 0x3F;
        }
        p
    };
    let palette = |instruction: u8, first: usize| {
        let mut data = [0u8; 16];
        for i in 0..8 {
            let n = first + i;
            let (r, g, b) = (
                ((n * 5) % 16) as u8,
                ((n * 11) % 16) as u8,
                ((n * 7) % 16) as u8,
            );
            data[2 * i] = (r << 2) | (g >> 2);
            data[2 * i + 1] = ((g & 3) << 4) | b;
        }
        pack(instruction, &data)
    };
    let mut out = Vec::with_capacity((tiles + 3) * 24);
    out.extend_from_slice(&pack(1, &[0]));
    out.extend_from_slice(&palette(30, 0));
    out.extend_from_slice(&palette(31, 8));
    for _ in 0..tiles {
        let mut data = [0u8; 16];
        // Inside the visible window (tile rows 1..=16, columns 1..=48), with a nonzero colour 1
        // and a set bit in every row, so every pack changes visible pixels.
        data[0] = next(16) as u8;
        data[1] = 1 + next(15) as u8;
        data[2] = 1 + next(16) as u8;
        data[3] = 1 + next(48) as u8;
        for row in &mut data[4..] {
            *row = 1 + next(63) as u8;
        }
        out.extend_from_slice(&pack(38, &data));
    }
    out
}

/// Whether `cpu_ns` reads a thread CPU clock, so the budget is enforced.
const THREAD_CLOCK: bool = cfg!(all(
    any(target_os = "macos", target_os = "linux"),
    target_pointer_width = "64"
));

#[cfg(all(
    any(target_os = "macos", target_os = "linux"),
    target_pointer_width = "64"
))]
fn cpu_ns() -> u64 {
    #[repr(C)]
    struct Timespec {
        seconds: i64,
        nanos: i64,
    }
    extern "C" {
        fn clock_gettime(clock: i32, out: *mut Timespec) -> i32;
    }
    const THREAD_CPU: i32 = if cfg!(target_os = "macos") { 16 } else { 3 };
    let mut t = Timespec {
        seconds: 0,
        nanos: 0,
    };
    // SAFETY: `t` is a valid timespec on these 64-bit targets.
    assert_eq!(
        unsafe { clock_gettime(THREAD_CPU, &mut t) },
        0,
        "thread CPU clock"
    );
    t.seconds as u64 * 1_000_000_000 + t.nanos as u64
}

#[cfg(not(all(
    any(target_os = "macos", target_os = "linux"),
    target_pointer_width = "64"
)))]
fn cpu_ns() -> u64 {
    use std::{sync::OnceLock, time::Instant};
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_nanos() as u64
}

fn main() -> ExitCode {
    let packs_per_frame = u64::from(PACKS_PER_SECOND) / FPS;
    let frames = WARMUP + ROUNDS as u64 * FRAMES_PER_ROUND;
    let stream = worst_stream((SEED_PACKS + frames * packs_per_frame) as usize);
    let mut decoder = Decoder::new(&stream);
    let mut before = vec![0u8; WINDOW_WIDTH * WINDOW_HEIGHT];
    let window = |decoder: &Decoder, out: &mut [u8]| {
        let rows = decoder.state().screen.chunks_exact(SCREEN_WIDTH);
        for (dst, row) in out.chunks_exact_mut(WINDOW_WIDTH).zip(rows.skip(BORDER_Y)) {
            dst.copy_from_slice(&row[BORDER_X..BORDER_X + WINDOW_WIDTH]);
        }
    };
    decoder.advance_to(SEED_PACKS);
    for applied in SEED_PACKS..decoder.pack_count() {
        window(&decoder, &mut before);
        decoder.advance_to(applied + 1);
        let rows = decoder.state().screen.chunks_exact(SCREEN_WIDTH);
        let changed = before
            .chunks_exact(WINDOW_WIDTH)
            .zip(rows.skip(BORDER_Y))
            .any(|(b, row)| *b != row[BORDER_X..BORDER_X + WINDOW_WIDTH]);
        assert!(changed, "pack {applied} leaves the window unchanged");
    }
    let mut decoder = Decoder::new(&stream);
    let mut presenter = Presenter::new(WIDTH, HEIGHT).expect("presenter size");
    let mut digest = 0xcbf2_9ce4_8422_2325u64;
    let mut frame = 0u64;
    let mut step = |decoder: &mut Decoder| {
        decoder.advance_to(SEED_PACKS + frame * packs_per_frame);
        let rgba = presenter.present(decoder, (frame * 1000 / FPS) as i64);
        digest =
            (digest ^ u64::from(black_box(rgba)[rgba.len() / 2])).wrapping_mul(0x100_0000_01b3);
        frame += 1;
    };
    for _ in 0..WARMUP {
        step(&mut decoder);
    }
    let means: Vec<u64> = (0..ROUNDS)
        .map(|_| {
            let start = cpu_ns();
            for _ in 0..FRAMES_PER_ROUND {
                step(&mut decoder);
            }
            (cpu_ns() - start) / FRAMES_PER_ROUND
        })
        .collect();
    let gated = *means.iter().min().expect("rounds");
    let ms = |ns: u64| ns as f64 / 1e6;
    let round_ms: Vec<String> = means.iter().map(|&m| format!("{:.3}", ms(m))).collect();
    let name = "cdg_present_budget worst 960x540 30 fps";
    let clock = if THREAD_CLOCK { "CPU" } else { "wall" };
    println!(
        "{name}: {ROUNDS}x{FRAMES_PER_ROUND} frames, round mean {clock} ms [{}] (digest {digest:016x})",
        round_ms.join(", ")
    );
    if !THREAD_CLOCK {
        println!(
            "{name}: SKIP: no thread CPU clock on this target; min round mean wall {:.3} ms, budget {:.3} ms not enforced",
            ms(gated),
            ms(BUDGET_NS)
        );
        return ExitCode::SUCCESS;
    }
    let pass = gated <= BUDGET_NS;
    println!(
        "{name}: {}: min round mean {:.3} ms, budget {:.3} ms",
        if pass { "PASS" } else { "FAIL" },
        ms(gated),
        ms(BUDGET_NS)
    );
    if pass {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
