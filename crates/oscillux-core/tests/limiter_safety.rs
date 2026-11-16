// SPDX-License-Identifier: AGPL-3.0-only
//! Policy edges, rejection without state mutation and untrusted timelines.

use oscillux_core::limiter::{analyze, Frame, FrameError, Limiter, Policy, MAX_CREDITED_GAP_MS};

fn flash(time_ms: f64) -> Frame {
    Frame {
        time_ms,
        broadband: 1.0,
        low: 1.0,
        mid: 1.0,
        high: 1.0,
        red: 1.0,
        area: 1.0,
    }
}

#[test]
fn fractional_rates_never_admit_more_than_the_budget() {
    for ceiling in [0.01, 0.5, 1.0, 1.5, 2.5, 2.999999, 3.0] {
        let policy = Policy {
            max_flash_hz: ceiling,
            ..Policy::DEFAULT
        };
        let mut limiter = Limiter::new(policy).unwrap();
        let input = [flash(0.0), flash(50.0), flash(500.0), flash(999.0)];
        let output = input.map(|f| limiter.process(f).unwrap());
        let result = analyze(&output, &policy).unwrap();
        assert!(result.peak_flash_hz <= ceiling, "{ceiling}: {result:?}");
        assert!(!result.exceeds(&policy));
    }
}

#[test]
fn sub_decimal_luminance_ceilings_are_never_rounded_up() {
    for ceiling in [0.3500006, 0.7999999, 0.1234561, 1e-10, f64::MIN_POSITIVE] {
        let policy = Policy {
            max_luminance_delta: ceiling,
            ..Policy::DEFAULT
        };
        let mut limiter = Limiter::new(policy).unwrap();
        let out = limiter.process(flash(0.0)).unwrap();
        for value in [out.broadband, out.low, out.mid, out.high] {
            assert!(value <= ceiling);
        }
        assert!(!analyze(&[out], &policy).unwrap().exceeds(&policy));
    }
    let policy = Policy {
        max_luminance_delta: 0.123456,
        ..Policy::DEFAULT
    };
    let input = Frame {
        broadband: 0.1234561,
        ..Frame::default()
    };
    assert!(analyze(&[input], &policy).unwrap().exceeds(&policy));
}

#[test]
fn zero_red_budget_and_window_expiry_are_enforced() {
    let policy = Policy {
        max_red_flashes: 0,
        max_flash_hz: 1.0,
        ..Policy::DEFAULT
    };
    let mut limiter = Limiter::new(policy).unwrap();
    // Dark frames keep every gap creditable.
    let input = [0.0, 250.0, 500.0, 750.0, 999.0, 1000.0].map(|time| match time {
        0.0 | 999.0 | 1000.0 => flash(time),
        _ => Frame::fail_safe(time),
    });
    let output = input.map(|f| limiter.process(f).unwrap());
    assert_eq!(output.map(|f| f.broadband), [0.8, 0.0, 0.0, 0.0, 0.4, 0.8]);
    assert!(output.iter().all(|f| f.red < 0.8));
    assert!(!analyze(&output, &policy).unwrap().exceeds(&policy));
}

#[test]
fn invalid_frames_leave_history_and_time_unchanged() {
    let mut baseline = Limiter::new(Policy::DEFAULT).unwrap();
    baseline.process(flash(0.0)).unwrap();
    baseline.process(flash(250.0)).unwrap();
    let mut invalid = vec![flash(f64::NAN), flash(f64::INFINITY), flash(249.0)];
    let setters: [fn(&mut Frame, f64); 6] = [
        |f, v| f.broadband = v,
        |f, v| f.low = v,
        |f, v| f.mid = v,
        |f, v| f.high = v,
        |f, v| f.red = v,
        |f, v| f.area = v,
    ];
    for set in setters {
        for value in [f64::NAN, f64::INFINITY, -0.1, 1.1] {
            let mut frame = flash(5000.0);
            set(&mut frame, value);
            invalid.push(frame);
        }
    }
    for frame in invalid {
        let mut actual = baseline.clone();
        assert!(actual.process(frame).is_err());
        let mut expected = baseline.clone();
        for time in [500.0, 1000.0, 1250.0] {
            assert_eq!(actual.process(flash(time)), expected.process(flash(time)));
        }
    }
}

#[test]
fn reset_allows_a_new_timeline_without_losing_policy() {
    let policy = Policy {
        max_red_flashes: 0,
        ..Policy::DEFAULT
    };
    let mut limiter = Limiter::new(policy).unwrap();
    limiter.process(flash(1000.0)).unwrap();
    assert_eq!(limiter.process(flash(0.0)), Err(FrameError::DecreasingTime));
    limiter.reset();
    assert_eq!(limiter.process(flash(0.0)).unwrap().broadband, 0.8);
    assert_eq!(*limiter.policy(), policy);
    // Only the frame after reset may go back in time.
    assert_eq!(
        limiter.process(flash(-1.0)),
        Err(FrameError::DecreasingTime)
    );
}

/// Flashes the output shows per real second, with frames presented every `frame_ms`.
fn worst_real_window(output: &[Frame], frame_ms: f64) -> usize {
    let real: Vec<Frame> = output
        .iter()
        .enumerate()
        .map(|(i, f)| Frame {
            time_ms: i as f64 * frame_ms,
            ..*f
        })
        .collect();
    let per_window = (1000.0 / frame_ms) as usize;
    real.windows(per_window.min(real.len()))
        .map(|w| w.iter().filter(|f| f.broadband >= 0.8).count())
        .max()
        .unwrap()
}

#[test]
fn reset_every_frame_cannot_reopen_the_window() {
    let mut limiter = Limiter::new(Policy::DEFAULT).unwrap();
    let output: Vec<Frame> = (0..120)
        .map(|_| {
            limiter.reset();
            limiter.process(flash(0.0)).unwrap()
        })
        .collect();
    // Every gap spans a reset, so a third flash could complete a strobe.
    assert_eq!(output.iter().filter(|f| f.broadband >= 0.8).count(), 2);
    assert!(output.iter().filter(|f| f.red >= 0.8).count() <= 3);
}

#[test]
fn untrusted_timestamps_cannot_outrun_wall_time() {
    // A host whose clock runs fast, has the wrong unit or jumps far ahead, presenting at 60 Hz.
    for step in [1000.0, 16_667.0, 1e12] {
        let mut limiter = Limiter::new(Policy::DEFAULT).unwrap();
        let output: Vec<Frame> = (0..600)
            .map(|i| limiter.process(flash(i as f64 * step)).unwrap())
            .collect();
        assert!(
            (1..=3).contains(&worst_real_window(&output, 1000.0 / 60.0)),
            "{step}"
        );
    }
    // At most MAX_CREDITED_GAP_MS is credited per frame, so a full window lasts four frames.
    let mut limiter = Limiter::new(Policy::DEFAULT).unwrap();
    let output: Vec<Frame> = (0..600)
        .map(|i| {
            limiter
                .process(flash(i as f64 * MAX_CREDITED_GAP_MS))
                .unwrap()
        })
        .collect();
    assert!(!analyze(&output, &Policy::DEFAULT)
        .unwrap()
        .exceeds(&Policy::DEFAULT));
}

#[test]
fn a_far_future_glitch_is_recovered_by_reset() {
    let mut limiter = Limiter::new(Policy::DEFAULT).unwrap();
    limiter.process(flash(0.0)).unwrap();
    limiter.process(flash(1e15)).unwrap();
    assert_eq!(
        limiter.process(flash(100.0)),
        Err(FrameError::DecreasingTime)
    );
    limiter.reset();
    let output = [100.0, 350.0, 600.0, 850.0, 1100.0, 1350.0]
        .map(|time| limiter.process(flash(time)).unwrap().broadband);
    // Both flashes keep their credited age, and a third across the unknown gaps could
    // complete a strobe.
    assert_eq!(output, [0.4, 0.4, 0.4, 0.4, 0.8, 0.8]);
}

#[test]
fn fail_safe_frame_has_no_signal() {
    let frame = Frame::fail_safe(42.0);
    assert_eq!(
        frame,
        Frame {
            time_ms: 42.0,
            ..Frame::default()
        }
    );
    let mut limiter = Limiter::new(Policy::DEFAULT).unwrap();
    assert_eq!(limiter.process(frame), Ok(frame));
}

#[test]
fn sequence_analysis_rejects_invalid_frames_and_order() {
    for frames in [[flash(1.0), flash(0.0)], [flash(0.0), flash(f64::NAN)]] {
        assert!(analyze(&frames, &Policy::DEFAULT).is_err());
    }
    let invalid = Frame {
        area: 1.1,
        ..flash(0.0)
    };
    assert!(analyze(&[invalid], &Policy::DEFAULT).is_err());
}
