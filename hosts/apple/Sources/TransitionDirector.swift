// SPDX-License-Identifier: AGPL-3.0-only
// The transition scheduler of crates/oscillux-core/src/transition.rs, ported
// for the Apple host, and the host-side director that uses it. Like
// hosts/web/transition.js it is line for line the model in
// conformance/transition/README.md: only + - * /, rounding up, comparisons and
// the easing polynomial on Doubles, so it matches
// conformance/transition/reference.json exactly.

struct TransitionScheduler {
    static let quantiseNone = 0, quantiseBeat = 1, quantiseBar = 2
    static let stateIdle = 0, statePreRoll = 1, stateWaiting = 2, stateBlending = 3, stateDone = 4
    static let easingLinear = 0, easingSmoothstep = 1
    static let minDurationSeconds = 0.8, maxDurationSeconds = 2.5
    static let minTempoBpm = 30.0, maxTempoBpm = 300.0, fallbackTempoBpm = 120.0

    struct Config {
        var easing = TransitionScheduler.easingLinear
        var beatsPerBar = 4
        var autoAdvanceBars = 0
        var durationBeats = 4.0
        var fallbackSeconds = 1.6
        var preRollSeconds = 0.5
        var minConfidence = 0.5

        var valid: Bool {
            easing >= 0 && easing <= TransitionScheduler.easingSmoothstep
                && beatsPerBar >= 1 && beatsPerBar <= 16
                && autoAdvanceBars >= 0 && autoAdvanceBars <= 1024
                && durationBeats > 0 && durationBeats <= 64
                && fallbackSeconds >= TransitionScheduler.minDurationSeconds
                && fallbackSeconds <= TransitionScheduler.maxDurationSeconds
                && preRollSeconds >= 0 && preRollSeconds <= 10
                && minConfidence >= 0 && minConfidence <= 1
        }
    }

    struct Clock {
        var timeSeconds = 0.0, beatPhase = 0.0, barPhase = 0.0, tempoBpm = 0.0, confidence = 0.0
    }

    struct Status {
        var progress = 0.0, requestSeconds = 0.0, startSeconds = 0.0, endSeconds = 0.0
        var state = 0, quantise = 0, autoRequested = 0
    }

    let config: Config
    private var scheduled = false
    private var request = 0.0, earliest = 0.0, start = 0.0, end = 0.0, quantise = 0
    private var anchor: Double?

    /// nil when the configuration is out of range.
    init?(_ config: Config = Config()) {
        guard config.valid else { return nil }
        self.config = config
    }

    mutating func reset() { scheduled = false; anchor = nil }

    private static func inUnit(_ v: Double) -> Bool { v >= 0 && v <= 1 }
    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? lo : v > hi ? hi : v }

    /// Beat period in seconds when the clock carries a confident beat, else nil.
    private func beatPeriod(_ k: Clock) -> Double? {
        let confident = k.confidence >= config.minConfidence && k.tempoBpm >= Self.minTempoBpm
            && k.tempoBpm <= Self.maxTempoBpm && Self.inUnit(k.beatPhase) && Self.inUnit(k.barPhase)
        return confident ? 60 / k.tempoBpm : nil
    }

    /// The first boundary request + (k - phase) * period at or after earliest.
    private static func nextBoundary(_ request: Double, _ earliest: Double, _ phase: Double, _ period: Double) -> Double {
        let k = ((earliest - request) / period + phase).rounded(.up)
        let at = request + (k - phase) * period
        return at < earliest ? earliest : at
    }

    /// Schedules a switch; false (and `out` unchanged) when refused.
    mutating func request(_ clock: Clock, _ quantise: Int, _ maxWaitSeconds: Double, _ out: inout Status) -> Bool {
        guard clock.timeSeconds.isFinite, quantise >= 0, quantise <= Self.quantiseBar,
              !maxWaitSeconds.isNaN, maxWaitSeconds >= 0 else { return false }
        let request = clock.timeSeconds, earliest = request + config.preRollSeconds
        var start = earliest, applied = Self.quantiseNone, duration = config.fallbackSeconds
        if let beat = beatPeriod(clock) {
            if quantise == Self.quantiseBar {
                let at = Self.nextBoundary(request, earliest, clock.barPhase, beat * Double(config.beatsPerBar))
                if at - earliest <= maxWaitSeconds { start = at; applied = Self.quantiseBar }
            }
            if quantise != Self.quantiseNone && applied == Self.quantiseNone {
                let at = Self.nextBoundary(request, earliest, clock.beatPhase, beat)
                if at - earliest <= maxWaitSeconds { start = at; applied = Self.quantiseBeat }
            }
            duration = Self.clamp(config.durationBeats * beat, Self.minDurationSeconds, Self.maxDurationSeconds)
        }
        scheduled = true
        self.request = request; self.earliest = earliest; self.start = start; end = start + duration
        self.quantise = applied
        anchor = nil
        statusAt(request, 0, &out)
        return true
    }

    func progress(_ t: Double) -> Double {
        if !scheduled || t.isNaN || t <= start { return 0 }
        if t >= end { return 1 }
        let u = Self.clamp((t - start) / (end - start), 0, 1)
        return config.easing == Self.easingSmoothstep ? u * u * (3 - 2 * u) : u
    }

    mutating func update(_ clock: Clock, _ out: inout Status) -> Bool {
        let t = clock.timeSeconds
        guard t.isFinite else { return false }
        if config.autoAdvanceBars > 0 && (!scheduled || t >= end) {
            if anchor == nil { anchor = scheduled ? end : t }
            let bar = (beatPeriod(clock) ?? 60 / Self.fallbackTempoBpm) * Double(config.beatsPerBar)
            if t - anchor! >= Double(config.autoAdvanceBars) * bar {
                _ = request(clock, Self.quantiseBar, bar, &out)
                statusAt(t, 1, &out)
                return true
            }
        }
        statusAt(t, 0, &out)
        return true
    }

    func status(_ t: Double, _ out: inout Status) -> Bool { statusAt(t, 0, &out); return true }

    private func statusAt(_ t: Double, _ autoRequested: Int, _ out: inout Status) {
        out.autoRequested = autoRequested
        guard scheduled else {
            out.progress = 0; out.requestSeconds = 0; out.startSeconds = 0; out.endSeconds = 0
            out.state = Self.stateIdle; out.quantise = 0
            return
        }
        out.state = t >= end ? Self.stateDone : t >= start ? Self.stateBlending
            : t >= earliest ? Self.stateWaiting : Self.statePreRoll
        out.progress = progress(t)
        out.requestSeconds = request; out.startSeconds = start; out.endSeconds = end
        out.quantise = quantise
    }
}

/// The host side of a switch: one scheduler at the default configuration
/// (linear progress: the transition shaders ease themselves), its beat clock
/// and its status, all stored inline. The host fills `clock` from the visible
/// music, calls request() when a switch begins and frame(t) on every frame of
/// it. hosts/web/transition.js has the same director.
struct TransitionDirector {
    private var scheduler = TransitionScheduler()!
    var quantise: Int
    var clock = TransitionScheduler.Clock()
    private(set) var status = TransitionScheduler.Status()

    init(quantise: Int = TransitionScheduler.quantiseBar) { self.quantise = quantise }

    /// Schedules a switch from `clock`: on the next bar or beat after the
    /// pre-roll, waiting at most one bar, or at once without a confident beat.
    @discardableResult
    mutating func request() -> Bool {
        let bar = Double(scheduler.config.beatsPerBar) * 60 / clock.tempoBpm
        return scheduler.request(clock, quantise, bar > 0 && bar < .infinity ? bar : 0, &status)
    }

    /// The blend progress at presentation time t; `status` holds the state.
    mutating func frame(_ t: Double) -> Double {
        _ = scheduler.status(t, &status)
        return status.progress
    }

    mutating func reset() { scheduler.reset(); _ = scheduler.status(0, &status) }
}
