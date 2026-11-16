// SPDX-License-Identifier: AGPL-3.0-only
//! Property tests: limiter output fed back through the analyzer never exceeds its policy.
//!
//! Sequences are drawn from a fixed-seed generator, so every run and every target checks the
//! same cases: mixed 4 to 144 Hz cadences with jitter, rate changes, occasional uncredited gaps,
//! general, red, combined, small-area and sub-threshold frames, under tightened policies.

use oscillux_core::limiter::{analyze, Frame, Limiter, Policy};

const SEQUENCES: usize = 400;
const FRAMES: usize = 240;

/// SplitMix64: a small deterministic generator, so the test needs no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)`.
    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }

    fn pick<T: Copy>(&mut self, items: &[T]) -> T {
        items[(self.next() % items.len() as u64) as usize]
    }

    fn between(&mut self, low: f64, high: f64) -> f64 {
        low + (high - low) * self.unit()
    }
}

fn policy(rng: &mut Rng) -> Policy {
    Policy {
        max_flash_hz: rng.pick(&[3.0, 3.0, 2.5, 2.0, 1.0, 0.5]),
        max_luminance_delta: rng.pick(&[0.8, 0.8, 0.79, 0.6, 0.41, 0.4, 0.35, 0.1]),
        max_flash_area: rng.pick(&[0.25, 0.2, 0.1]),
        max_red_flashes: rng.pick(&[0, 1, 2, 3, 3]),
        strobe_banned: true,
    }
}

fn content(rng: &mut Rng, time_ms: f64) -> Frame {
    let mut frame = Frame::fail_safe(time_ms);
    let onset = |rng: &mut Rng| match rng.next() % 3 {
        0 => rng.between(0.8, 1.0),
        1 => 1.0,
        _ => rng.between(0.0, 0.8),
    };
    match rng.next() % 6 {
        0 => return frame,
        1 => frame.broadband = onset(rng),
        2 => frame.red = onset(rng),
        3 => {
            frame.broadband = onset(rng);
            frame.red = onset(rng);
        }
        _ => {
            frame.broadband = rng.between(0.8, 1.0);
            frame.red = rng.pick(&[0.0, 1.0]);
        }
    }
    frame.low = rng.unit();
    frame.mid = rng.unit();
    frame.high = rng.pick(&[0.0, 1.0, frame.broadband]);
    frame.area = match rng.next() % 4 {
        0 => rng.pick(&[0.1, 0.2, 0.25, 0.3]),
        1 => rng.unit(),
        _ => 1.0,
    };
    frame
}

/// Frames at runs of 4 to 144 Hz with up to 15% jitter; about one gap in fifty is a
/// discontinuity longer than the credited maximum.
fn sequence(rng: &mut Rng) -> Vec<Frame> {
    let mut frames = Vec::with_capacity(FRAMES);
    let mut time_ms = 0.0;
    let mut hz = 60.0;
    let mut run = 0;
    while frames.len() < FRAMES {
        if run == 0 {
            hz = rng.pick(&[60.0, 120.0, 144.0, 30.0, 4.0]);
            run = 10 + rng.next() % 50;
        }
        run -= 1;
        frames.push(content(rng, time_ms));
        time_ms += if rng.next() % 50 == 0 {
            rng.between(251.0, 2000.0)
        } else {
            1000.0 / hz * rng.between(0.85, 1.15)
        };
    }
    frames
}

fn run(policy: Policy, input: &[Frame]) -> Vec<Frame> {
    let mut limiter = Limiter::new(policy).unwrap();
    input.iter().map(|f| limiter.process(*f).unwrap()).collect()
}

fn onsets(f: &Frame) -> [f64; 4] {
    [f.broadband, f.low, f.mid, f.high]
}

#[test]
fn limiter_output_never_exceeds_its_policy() {
    let mut rng = Rng(0x05C1_11F7);
    for case in 0..SEQUENCES {
        let policy = policy(&mut rng);
        let input = sequence(&mut rng);
        let output = run(policy, &input);
        let result = analyze(&output, &policy).unwrap();
        assert!(
            !result.exceeds(&policy),
            "case {case}: {policy:?} {result:?}"
        );

        // The same flashes are admitted at the default ceiling, where they are visible to the
        // analyzer, so the budget holds there too.
        let loose = Policy {
            max_luminance_delta: Policy::DEFAULT.max_luminance_delta,
            ..policy
        };
        let loose_output = run(loose, &input);
        let loose_result = analyze(&loose_output, &loose).unwrap();
        assert!(
            !loose_result.exceeds(&loose),
            "case {case}: {loose_result:?}"
        );

        // Tightening the ceiling only lowers onsets to it: it neither changes which flashes are
        // admitted nor raises any onset.
        let cap = policy.max_luminance_delta;
        let level = ((cap * 1_000_000.0).floor() / 1_000_000.0).min(cap);
        for ((i, o), l) in input.iter().zip(&output).zip(&loose_output) {
            let at = format!("case {case} frame at {} ms", i.time_ms);
            assert_eq!((o.time_ms, o.area), (i.time_ms, i.area), "{at}");
            assert_eq!(o.red, l.red, "{at}");
            assert!(o.red <= i.red, "{at}");
            for ((o, l), i) in onsets(o).iter().zip(onsets(l)).zip(onsets(i)) {
                assert_eq!(*o, l.min(level), "{at}");
                assert!(*o <= i, "{at}");
            }
        }
    }
}
