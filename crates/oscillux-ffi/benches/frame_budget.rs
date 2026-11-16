// SPDX-License-Identifier: AGPL-3.0-only
//! Host per-frame budget check: DSP, limiter, mapping, reaction sampling and packing through the
//! public C ABI.
//!
//! Mirrors `benches/native-frame.c`: one frame is one 512-sample hop at 48 kHz that must emit
//! exactly one analysis frame, followed by a limiter step, mapping, a reaction push and sample
//! (which the C bench does not run) and a 160-byte pack. The push
//! is `oscillux_dsp_push_ext_f32`, so each frame also writes its `OscilluxDspFrameExt`
//! (descriptors, beat and adaptive levels; the analyzer computes all three on every hop whichever
//! push is used). The window is primed and warmed up before timing; buffers and handles exist
//! before the first timed frame.
//!
//! Noise policy: the frames are timed in `ROUNDS` rounds; each round's median is robust to
//! preemption of a few frames, and the gated statistic is the minimum round median, so the
//! check fails only when every round is slow. `BUDGET_NS` leaves wide headroom for a busy host.
//!
//! Every DSP behaviour version is timed (`conformance/dsp/README.md`), the default version 2
//! first; each must meet the budget and prints its own output digest. The output digest covers
//! the limiter and packed bytes; the stages digest covers the ext beat and levels.
//!
//! CD+G (OSC-CDG) is timed separately on a 5-minute synthetic stream (`conformance/cdg/README.md`
//! LCG): a frame is `oscillux_cdg_advance_to_time` at 60 Hz, `oscillux_cdg_state` and a keyed
//! `oscillux_cdg_window_rgba`, under the same budget; seeks are checked against a sequential
//! decode and gated at `SEEK_BUDGET_NS` on the worst target's fastest of `SEEK_REPEATS` tries.
use oscillux::cdg::*;
use oscillux::dsp::*;
use oscillux::limiter::*;
use oscillux::{mapping::*, oscillux_abi_version, packing::*, reaction::*, OSCILLUX_OK};
use oscillux_core::dsp::{Beat, DspFrame, Levels};
use std::{hint::black_box, process::ExitCode, ptr::null_mut, time::Instant};

/// Gated limit on the minimum round median, in nanoseconds: 3% of a 16.7 ms 60 Hz frame.
const BUDGET_NS: u64 = 500_000;
const HOP: usize = 512;
const SIGNAL_BLOCKS: usize = 32;
const WARMUP: usize = 256;
const ROUNDS: usize = 9;
const FRAMES_PER_ROUND: usize = 1024;
const PACKED_BYTES: usize = 160;

struct Handles {
    dsp: *mut OscilluxDsp,
    limiter: *mut OscilluxLimiter,
    mapper: *mut OscilluxMapper,
    reaction: *mut OscilluxReactionSampler,
    packer: *mut OscilluxPacker,
}

impl Drop for Handles {
    fn drop(&mut self) {
        unsafe {
            oscillux_dsp_destroy(self.dsp);
            oscillux_limiter_destroy(self.limiter);
            oscillux_mapping_destroy(self.mapper);
            oscillux_reaction_destroy(self.reaction);
            oscillux_packer_destroy(self.packer);
        }
    }
}

fn check(status: i32, operation: &str) {
    assert_eq!(status, OSCILLUX_OK, "{operation} failed");
}

impl Handles {
    fn new(behavior_version: u32) -> Self {
        let mut h = Self {
            dsp: null_mut(),
            limiter: null_mut(),
            mapper: null_mut(),
            reaction: null_mut(),
            packer: null_mut(),
        };
        let fields = [
            OscilluxUniformField {
                source: 0,
                source_offset: 0,
                components: 9,
                offset: 0,
                stride: 4,
            },
            OscilluxUniformField {
                source: 1,
                source_offset: 0,
                components: 24,
                offset: 48,
                stride: 4,
            },
            OscilluxUniformField {
                source: 2,
                source_offset: 0,
                components: 4,
                offset: 144,
                stride: 4,
            },
        ];
        unsafe {
            let mut config = OscilluxDspVersionedConfig::default();
            check(
                oscillux_dsp_versioned_config_default(&mut config),
                "DSP config",
            );
            assert_eq!(
                config.config.hop_samples as usize, HOP,
                "default hop changed"
            );
            config.behavior_version = behavior_version;
            check(
                oscillux_dsp_create_versioned(&config, &mut h.dsp),
                "DSP create",
            );
            let mut policy = OscilluxLimiterPolicy::default();
            check(oscillux_limiter_policy_default(&mut policy), "policy");
            check(oscillux_limiter_create(&policy, &mut h.limiter), "limiter");
            let mut mapping = OscilluxMappingConfig::default();
            check(oscillux_mapping_config_default(&mut mapping), "mapping");
            check(oscillux_mapping_create(&mapping, &mut h.mapper), "mapper");
            let mut reaction = OscilluxReactionConfig::default();
            check(
                oscillux_reaction_config_default(behavior_version, 48_000, &mut reaction),
                "reaction config",
            );
            check(
                oscillux_reaction_create(&reaction, &mut h.reaction),
                "reaction",
            );
            let (ptr, len) = (fields.as_ptr(), fields.len());
            check(
                oscillux_packer_create(ptr, len, PACKED_BYTES, &mut h.packer),
                "packer",
            );
        }
        h
    }
}

/// The three-tone, gated-envelope signal `benches/native-frame.c` uses.
fn signal() -> Vec<[f32; HOP]> {
    let tau = std::f64::consts::TAU;
    (0..SIGNAL_BLOCKS)
        .map(|block| {
            let envelope = if block % 8 < 3 { 1.0 } else { 0.2 };
            std::array::from_fn(|at| {
                let t = (block * HOP + at) as f64 / 48_000.0;
                let tones = 0.35 * (tau * 60.0 * t).sin()
                    + 0.20 * (tau * 1_000.0 * t).sin()
                    + 0.15 * (tau * 6_000.0 * t).sin();
                (envelope * tones) as f32
            })
        })
        .collect()
}

/// One frame through the measured path, writing its ext to `ext`; returns the limiter output.
unsafe fn frame(
    h: &Handles,
    pcm: &[f32; HOP],
    ext: &mut OscilluxDspFrameExt,
    packed: &mut [u8; PACKED_BYTES],
) -> OscilluxLimiterFrame {
    let mut out = DspFrame::ZERO;
    let mut push = OscilluxDspPushResult::default();
    let (p, n) = (pcm.as_ptr(), HOP);
    let status = oscillux_dsp_push_ext_f32(h.dsp, p, n, 1, &mut out, ext, 1, &mut push);
    check(status, "DSP push");
    assert_eq!(
        (push.consumed, push.produced),
        (HOP, 1),
        "one frame per hop"
    );
    let unit = |v: f64| v.clamp(0.0, 1.0);
    let input = OscilluxLimiterFrame {
        time_ms: out.media_time_ms,
        broadband: unit(out.onset.broadband),
        low: unit(out.onset.low),
        mid: unit(out.onset.mid),
        high: unit(out.onset.high),
        red: unit(out.spectrum[23]),
        area: 1.0,
    };
    let mut limited = OscilluxLimiterFrame::default();
    check(
        oscillux_limiter_process(h.limiter, &input, &mut limited),
        "limiter",
    );
    let mut mapped = OscilluxMapped::ZERO;
    check(
        oscillux_mapping_process(h.mapper, &out, 0, &mut mapped),
        "mapping",
    );
    // A live host's sampler: this hop now, one display frame sampled 20 ms of output later.
    let media = out.media_time_ms;
    check(
        oscillux_reaction_push(h.reaction, media, &mapped, &ext.beat),
        "reaction push",
    );
    let mut reaction = OscilluxReaction::ZERO;
    check(
        oscillux_reaction_sample(h.reaction, media + 20.0, &mut reaction),
        "reaction sample",
    );
    black_box(&reaction);
    let host = [640.0, 360.0, 0.5, 1.0];
    let (dst, cap) = (packed.as_mut_ptr(), packed.len());
    check(
        oscillux_packer_pack(h.packer, &mapped, host.as_ptr(), host.len(), dst, cap),
        "pack",
    );
    limited
}

/// Folds one frame's outputs into an FNV-1a digest, so builds can be compared bit for bit.
fn digest(hash: u64, packed: &[u8], limited: &OscilluxLimiterFrame) -> u64 {
    let l = limited;
    let scalars = [l.time_ms, l.broadband, l.low, l.mid, l.high, l.red, l.area];
    let limiter_bytes = scalars.iter().flat_map(|v| v.to_bits().to_le_bytes());
    fnv1a(hash, packed.iter().copied().chain(limiter_bytes))
}

/// Folds one frame's beat and level outputs into an FNV-1a digest.
fn stages_digest(hash: u64, beat: &Beat, levels: &Levels) -> u64 {
    let b = beat;
    let reals = [b.tempo_bpm, b.beat_phase, b.bar_phase, b.confidence];
    let counts = [b.beat, b.downbeat, b.beat_in_bar];
    let level_reals = levels.relative_groups.iter().chain(&levels.absolute_groups);
    let level_reals = level_reals.chain(&levels.relative_bands);
    let bytes = reals
        .iter()
        .chain(level_reals)
        .flat_map(|v| v.to_bits().to_le_bytes());
    fnv1a(
        hash,
        bytes.chain(counts.iter().flat_map(|n| n.to_le_bytes())),
    )
}

fn fnv1a(hash: u64, bytes: impl Iterator<Item = u8>) -> u64 {
    bytes.fold(hash, |h, byte| {
        (h ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

fn median(sorted: &[u64]) -> u64 {
    sorted[sorted.len() / 2]
}

/// Times `ROUNDS` x `FRAMES_PER_ROUND` frames of one DSP behaviour version; returns the
/// per-frame times by round, the output digest and the stages digest.
fn measure(behavior_version: u32, pcm: &[[f32; HOP]]) -> (Vec<Vec<u64>>, u64, u64) {
    let h = Handles::new(behavior_version);
    let mut ext = OscilluxDspFrameExt::default();
    let mut packed = [0u8; PACKED_BYTES];
    let mut rounds = vec![vec![0u64; FRAMES_PER_ROUND]; ROUNDS];
    let mut witness = 0xcbf2_9ce4_8422_2325u64;
    let mut stages = witness;
    let mut block = 3;
    unsafe {
        check(oscillux_dsp_begin_segment(h.dsp, 0.0, 0), "segment");
        // Prime 1536 samples so every following 512-sample push emits one 2048-sample frame.
        let mut out = DspFrame::ZERO;
        let mut push = OscilluxDspPushResult::default();
        for pcm in &pcm[..3] {
            let (p, frames) = (pcm.as_ptr(), &mut out);
            check(
                oscillux_dsp_push_f32(h.dsp, p, HOP, 1, frames, 1, &mut push),
                "prime",
            );
            assert_eq!((push.consumed, push.produced), (HOP, 0), "priming emitted");
        }
        for _ in 0..WARMUP {
            let pcm = &pcm[block % SIGNAL_BLOCKS];
            let limited = frame(&h, pcm, &mut ext, &mut packed);
            witness = digest(witness, &packed, &limited);
            stages = stages_digest(stages, &ext.beat, &ext.levels);
            block += 1;
        }
        for round in &mut rounds {
            for slot in round.iter_mut() {
                let start = Instant::now();
                let pcm = black_box(&pcm[block % SIGNAL_BLOCKS]);
                let limited = frame(&h, pcm, &mut ext, &mut packed);
                *slot = start.elapsed().as_nanos() as u64;
                witness = digest(witness, black_box(&packed), &limited);
                let ext = black_box(&ext);
                stages = stages_digest(stages, &ext.beat, &ext.levels);
                block += 1;
            }
        }
    }
    (rounds, witness, stages)
}

/// Prints one version's statistics; returns whether its minimum round median meets the budget.
fn report(behavior_version: u32, mut rounds: Vec<Vec<u64>>, witness: u64, stages: u64) -> bool {
    let medians: Vec<u64> = rounds
        .iter_mut()
        .map(|round| {
            round.sort_unstable();
            median(round)
        })
        .collect();
    let mut all: Vec<u64> = rounds.concat();
    all.sort_unstable();
    let gated = *medians.iter().min().expect("rounds");
    let ms = |ns: u64| ns as f64 / 1e6;
    let round_ms: Vec<String> = medians.iter().map(|&m| format!("{:.4}", ms(m))).collect();
    let name = format!("frame_budget dsp v{behavior_version}");
    println!(
        "{name}: {ROUNDS}x{FRAMES_PER_ROUND} frames, round medians ms [{}]",
        round_ms.join(", ")
    );
    println!(
        "{name}: all frames p50 {:.4} ms, p99 {:.4} ms, max {:.4} ms (output digest {witness:016x}, \
         stages digest {stages:016x})",
        ms(median(&all)),
        ms(all[all.len() * 99 / 100]),
        ms(all[all.len() - 1]),
    );
    let verdict = if gated <= BUDGET_NS { "PASS" } else { "FAIL" };
    println!(
        "{name}: {verdict}: min round median {:.4} ms, budget {:.4} ms",
        ms(gated),
        ms(BUDGET_NS)
    );
    gated <= BUDGET_NS
}

// ==== CD+G (OSC-CDG) ====

/// Gated limit on the worst seek, nanoseconds (OSC-CDG acceptance: 2 ms).
const SEEK_BUDGET_NS: u64 = 2_000_000;
const SEEK_TARGETS: usize = 4096;
const SEEK_REPEATS: usize = 5;
const CDG_FPS: f64 = 60.0;

/// The `lcg(seed)` pack stream of `conformance/cdg/README.md`.
fn cdg_lcg_stream(seed: u64, count: usize) -> Vec<u8> {
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
    let mut out = Vec::with_capacity(count * 24);
    for _ in 0..count {
        let mut p = [0u8; 24];
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

/// A stream whose every pack is the same TV-graphics `instruction` with `data` (the
/// worst case for checkpoint replay when the instruction rewrites the whole screen).
fn cdg_uniform_stream(instruction: u8, data: [u8; 16], count: usize) -> Vec<u8> {
    let mut pack = [0u8; 24];
    pack[0] = 9;
    pack[1] = instruction;
    pack[4..20].copy_from_slice(&data);
    pack.repeat(count)
}

struct Cdg(*mut OscilluxCdg);

impl Drop for Cdg {
    fn drop(&mut self) {
        unsafe { oscillux_cdg_destroy(self.0) }
    }
}

impl Cdg {
    fn new(stream: &[u8]) -> Self {
        let mut handle = null_mut();
        check(
            unsafe { oscillux_cdg_create(stream.as_ptr(), stream.len(), &mut handle) },
            "CD+G create",
        );
        Self(handle)
    }
    fn screen_digest(&self, screen: &mut [u8]) -> u64 {
        check(
            unsafe { oscillux_cdg_screen(self.0, screen.as_mut_ptr(), screen.len()) },
            "CD+G screen",
        );
        fnv1a(0xcbf2_9ce4_8422_2325, screen.iter().copied())
    }
}

/// Times 60 Hz playback frames (advance, state, keyed window) over a 5-minute stream; returns
/// the per-frame times by round and a digest of the windows.
fn measure_cdg_frames(stream: &[u8]) -> (Vec<Vec<u64>>, u64) {
    let cdg = Cdg::new(stream);
    let mut state = OscilluxCdgState {
        struct_size: std::mem::size_of::<OscilluxCdgState>() as u32,
        ..Default::default()
    };
    let mut rgba = vec![0u8; WINDOW_RGBA_BYTES as usize];
    let mut rounds = vec![vec![0u64; FRAMES_PER_ROUND]; ROUNDS];
    let mut witness = 0xcbf2_9ce4_8422_2325u64;
    let frames = (stream.len() / 24) as f64 / f64::from(PACKS_PER_SECOND) * CDG_FPS;
    let mut frame = 0u64;
    let mut step = |slot: &mut u64| unsafe {
        // Wrap to the start at the end of the stream: a backward seek, as a loop would.
        let seconds = (frame as f64 % frames) / CDG_FPS;
        let start = Instant::now();
        check(
            oscillux_cdg_advance_to_time(cdg.0, black_box(seconds)),
            "CD+G advance",
        );
        check(oscillux_cdg_state(cdg.0, &mut state), "CD+G state");
        let (ptr, len) = (rgba.as_mut_ptr(), rgba.len());
        check(
            oscillux_cdg_window_rgba(cdg.0, KEY_TRANSPARENT_TABLE, 0, ptr, len),
            "CD+G window",
        );
        *slot = start.elapsed().as_nanos() as u64;
        let changes = black_box(&state).changes;
        witness = fnv1a(witness, changes.to_le_bytes().into_iter());
        witness = fnv1a(
            witness,
            black_box(&rgba)[len / 2..len / 2 + 64].iter().copied(),
        );
        frame += 1;
    };
    let mut warm = 0;
    for _ in 0..WARMUP {
        step(&mut warm);
    }
    for round in &mut rounds {
        for slot in round.iter_mut() {
            step(slot);
        }
    }
    (rounds, witness)
}

/// Seeks to `SEEK_TARGETS` pseudo-random targets in shuffled order, each from a distant
/// position, checks every screen against a sequential decode, and returns each target's fastest
/// of `SEEK_REPEATS` seek times and the checkpoint count.
fn measure_cdg_seeks(stream: &[u8], seed: u64) -> (Vec<u64>, usize) {
    let count = (stream.len() / 24) as u64;
    let mut s = seed;
    let mut next = move || {
        s = s
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        s >> 33
    };
    let mut targets: Vec<u64> = (0..SEEK_TARGETS).map(|_| next() % (count + 1)).collect();
    targets.extend([0, count]);
    let mut screen = vec![0u8; SCREEN_PIXELS as usize];
    // Reference: a sequential decode through the sorted targets.
    let mut sorted = targets.clone();
    sorted.sort_unstable();
    sorted.dedup();
    let reference = Cdg::new(stream);
    let expected: std::collections::HashMap<u64, u64> = sorted
        .iter()
        .map(|&t| {
            check(
                unsafe { oscillux_cdg_advance_to_pack(reference.0, t) },
                "CD+G advance",
            );
            (t, reference.screen_digest(&mut screen))
        })
        .collect();
    let cdg = Cdg::new(stream);
    let mut best = vec![u64::MAX; targets.len()];
    for _ in 0..SEEK_REPEATS {
        for (i, &target) in targets.iter().enumerate() {
            let from = (target + count / 2) % (count + 1);
            unsafe {
                check(oscillux_cdg_advance_to_pack(cdg.0, from), "CD+G advance");
                let start = Instant::now();
                check(
                    oscillux_cdg_advance_to_pack(cdg.0, black_box(target)),
                    "CD+G seek",
                );
                best[i] = best[i].min(start.elapsed().as_nanos() as u64);
            }
            assert_eq!(
                cdg.screen_digest(&mut screen),
                expected[&target],
                "seek to {target} is not the sequential screen"
            );
        }
    }
    let checkpoints = unsafe {
        let mut state = OscilluxCdgState {
            struct_size: std::mem::size_of::<OscilluxCdgState>() as u32,
            ..Default::default()
        };
        check(oscillux_cdg_state(cdg.0, &mut state), "CD+G state");
        assert_eq!(state.pack_count, count);
        oscillux_core::cdg::Decoder::new(stream).checkpoint_count()
    };
    (best, checkpoints)
}

/// Prints the seek statistics; returns whether the worst target meets `SEEK_BUDGET_NS`.
fn report_seeks(name: &str, packs: usize, mut best: Vec<u64>, checkpoints: usize) -> bool {
    best.sort_unstable();
    let worst = best[best.len() - 1];
    let ms = |ns: u64| ns as f64 / 1e6;
    let verdict = if worst <= SEEK_BUDGET_NS {
        "PASS"
    } else {
        "FAIL"
    };
    println!(
        "frame_budget cdg seek {name}: {packs} packs, {checkpoints} checkpoints, {} targets x \
         {SEEK_REPEATS} (fastest per target), p50 {:.4} ms, p99 {:.4} ms; {verdict}: worst {:.4} ms, \
         budget {:.4} ms",
        best.len(),
        ms(median(&best)),
        ms(best[best.len() * 99 / 100]),
        ms(worst),
        ms(SEEK_BUDGET_NS)
    );
    worst <= SEEK_BUDGET_NS
}

fn cdg_budget() -> bool {
    let five_minutes = cdg_lcg_stream(0x5EED0300, 90_000);
    let (rounds, witness) = measure_cdg_frames(&five_minutes);
    let mut pass = report_rounds(
        "frame_budget cdg 60 Hz",
        rounds,
        &format!("window digest {witness:016x}"),
    );
    let (best, checkpoints) = measure_cdg_seeks(&five_minutes, 1);
    pass &= report_seeks("5-minute lcg", 90_000, best, checkpoints);
    // Adversarial: every pack rewrites the whole screen, so every checkpoint interval replays
    // the most full-screen work the budget allows. 30 s each: seek cost does not depend on length.
    let mut scroll = [0u8; 16];
    scroll[1] = 0x10;
    scroll[2] = 0x10;
    for (name, stream) in [
        ("all scroll copy", cdg_uniform_stream(24, scroll, 9_000)),
        ("all memory preset", cdg_uniform_stream(1, [5; 16], 9_000)),
    ] {
        let (best, checkpoints) = measure_cdg_seeks(&stream, 2);
        pass &= report_seeks(name, 9_000, best, checkpoints);
    }
    pass
}

/// Prints frame statistics under `name`; returns whether the minimum round median meets the budget.
fn report_rounds(name: &str, mut rounds: Vec<Vec<u64>>, digests: &str) -> bool {
    let medians: Vec<u64> = rounds
        .iter_mut()
        .map(|round| {
            round.sort_unstable();
            median(round)
        })
        .collect();
    let mut all: Vec<u64> = rounds.concat();
    all.sort_unstable();
    let gated = *medians.iter().min().expect("rounds");
    let ms = |ns: u64| ns as f64 / 1e6;
    let round_ms: Vec<String> = medians.iter().map(|&m| format!("{:.4}", ms(m))).collect();
    println!(
        "{name}: {ROUNDS}x{FRAMES_PER_ROUND} frames, round medians ms [{}]",
        round_ms.join(", ")
    );
    println!(
        "{name}: all frames p50 {:.4} ms, p99 {:.4} ms, max {:.4} ms ({digests})",
        ms(median(&all)),
        ms(all[all.len() * 99 / 100]),
        ms(all[all.len() - 1]),
    );
    let verdict = if gated <= BUDGET_NS { "PASS" } else { "FAIL" };
    println!(
        "{name}: {verdict}: min round median {:.4} ms, budget {:.4} ms",
        ms(gated),
        ms(BUDGET_NS)
    );
    gated <= BUDGET_NS
}

fn main() -> ExitCode {
    assert_eq!(oscillux_abi_version(), oscillux::ABI_VERSION);
    let pcm = signal();
    let mut pass = true;
    for version in [
        OSCILLUX_DSP_BEHAVIOR_V2,
        OSCILLUX_DSP_BEHAVIOR_V3,
        OSCILLUX_DSP_BEHAVIOR_V4,
        OSCILLUX_DSP_BEHAVIOR_V1,
    ] {
        let (rounds, witness, stages) = measure(version, &pcm);
        pass &= report(version, rounds, witness, stages);
    }
    pass &= measure_with_grid_clock(&pcm);
    pass &= cdg_budget();
    if pass {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

// ==== Beat grid clock (OSC-BEAT-GRID) ========================================================
// A host playing a file reads the offline grid once per frame. The grid is built from a 60 s
// click train before timing (analysis is off the frame path); each timed frame is the version 2
// frame above followed by `oscillux_beatgrid_clock` at that frame's media time.

/// A 60 s, 48 kHz mono 120 BPM click train: a 10 ms decaying 1 kHz click on every beat.
fn grid_signal() -> Vec<f32> {
    let mut pcm = vec![0.0f32; 48_000 * 60];
    for beat in 0..120 {
        let at = beat * 24_000;
        for (i, s) in pcm[at..at + 480].iter_mut().enumerate() {
            let t = i as f64 / 48_000.0;
            *s = (0.8 * (-t * 400.0).exp() * (std::f64::consts::TAU * 1_000.0 * t).sin()) as f32;
        }
    }
    pcm
}

/// Times the version 2 frame plus one grid clock query; prints and returns whether it passes.
fn measure_with_grid_clock(pcm: &[[f32; HOP]]) -> bool {
    use oscillux::beatgrid::*;
    let clicks = grid_signal();
    let mut config = OscilluxBeatGridConfig::default();
    let mut grid = null_mut();
    unsafe {
        check(oscillux_beatgrid_config_default(&mut config), "grid config");
        (config.sample_rate_hz, config.channels) = (48_000, 1);
        let samples = clicks.as_ptr();
        let status = oscillux_beatgrid_create(&config, samples, clicks.len(), &mut grid);
        check(status, "grid create");
    }
    let h = Handles::new(OSCILLUX_DSP_BEHAVIOR_V2);
    let mut ext = OscilluxDspFrameExt::default();
    let mut packed = [0u8; PACKED_BYTES];
    let mut clock = OscilluxBeatGridClock::default();
    let mut rounds = vec![vec![0u64; FRAMES_PER_ROUND]; ROUNDS];
    let mut witness = 0xcbf2_9ce4_8422_2325u64;
    let mut block = 3;
    unsafe {
        check(oscillux_dsp_begin_segment(h.dsp, 0.0, 0), "segment");
        let mut out = DspFrame::ZERO;
        let mut push = OscilluxDspPushResult::default();
        for pcm in &pcm[..3] {
            let status = oscillux_dsp_push_f32(h.dsp, pcm.as_ptr(), HOP, 1, &mut out, 1, &mut push);
            check(status, "prime");
        }
        let media = |block: usize| (block * HOP) as f64 / 48_000.0 % 60.0;
        for _ in 0..WARMUP {
            frame(&h, &pcm[block % SIGNAL_BLOCKS], &mut ext, &mut packed);
            check(
                oscillux_beatgrid_clock(grid, media(block), &mut clock),
                "clock",
            );
            block += 1;
        }
        for round in &mut rounds {
            for slot in round.iter_mut() {
                let start = Instant::now();
                let pcm = black_box(&pcm[block % SIGNAL_BLOCKS]);
                frame(&h, pcm, &mut ext, &mut packed);
                let status = oscillux_beatgrid_clock(grid, black_box(media(block)), &mut clock);
                *slot = start.elapsed().as_nanos() as u64;
                check(status, "clock");
                let c = black_box(&clock);
                witness = fnv1a(witness, c.beat_phase.to_le_bytes().into_iter());
                witness = fnv1a(witness, c.beat_index.to_le_bytes().into_iter());
                block += 1;
            }
        }
        oscillux_beatgrid_destroy(grid);
    }
    let medians: Vec<u64> = rounds
        .iter_mut()
        .map(|round| {
            round.sort_unstable();
            median(round)
        })
        .collect();
    let gated = *medians.iter().min().expect("rounds");
    let ms = |ns: u64| ns as f64 / 1e6;
    let round_ms: Vec<String> = medians.iter().map(|&m| format!("{:.4}", ms(m))).collect();
    let name = "frame_budget dsp v2 + beat grid clock";
    println!(
        "{name}: {ROUNDS}x{FRAMES_PER_ROUND} frames, round medians ms [{}] (clock digest {witness:016x})",
        round_ms.join(", ")
    );
    let verdict = if gated <= BUDGET_NS { "PASS" } else { "FAIL" };
    println!(
        "{name}: {verdict}: min round median {:.4} ms, budget {:.4} ms",
        ms(gated),
        ms(BUDGET_NS)
    );
    gated <= BUDGET_NS
}
