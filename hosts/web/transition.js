// SPDX-License-Identifier: AGPL-3.0-only
// The transition scheduler of crates/oscillux-core/src/transition.rs, ported
// for the web host, and the host-side director that uses it. The scheduler is
// line for line the model in conformance/transition/README.md: only + - * /,
// Math.ceil, comparisons and the easing polynomial on doubles, so it matches
// conformance/transition/reference.json exactly (tools/shader/test-transition.mjs).
// hosts/apple/Sources/TransitionDirector.swift is the same port in Swift.

export const QUANTISE_NONE = 0, QUANTISE_BEAT = 1, QUANTISE_BAR = 2;
export const STATE_IDLE = 0, STATE_PRE_ROLL = 1, STATE_WAITING = 2, STATE_BLENDING = 3, STATE_DONE = 4;
export const EASING_LINEAR = 0, EASING_SMOOTHSTEP = 1;
export const MIN_DURATION_SECONDS = 0.8, MAX_DURATION_SECONDS = 2.5;
export const MIN_TEMPO_BPM = 30, MAX_TEMPO_BPM = 300, FALLBACK_TEMPO_BPM = 120;

export const DEFAULT_CONFIG = Object.freeze({
  easing: EASING_LINEAR, beatsPerBar: 4, autoAdvanceBars: 0, durationBeats: 4,
  fallbackSeconds: 1.6, preRollSeconds: 0.5, minConfidence: 0.5,
});

function validConfig(c) {
  return Number.isInteger(c.easing) && c.easing >= 0 && c.easing <= EASING_SMOOTHSTEP
    && Number.isInteger(c.beatsPerBar) && c.beatsPerBar >= 1 && c.beatsPerBar <= 16
    && Number.isInteger(c.autoAdvanceBars) && c.autoAdvanceBars >= 0 && c.autoAdvanceBars <= 1024
    && c.durationBeats > 0 && c.durationBeats <= 64
    && c.fallbackSeconds >= MIN_DURATION_SECONDS && c.fallbackSeconds <= MAX_DURATION_SECONDS
    && c.preRollSeconds >= 0 && c.preRollSeconds <= 10
    && c.minConfidence >= 0 && c.minConfidence <= 1;
}

const inUnit = v => v >= 0 && v <= 1;

// Beat period in seconds when the clock carries a confident beat, else null.
function beatPeriod(c, k) {
  const confident = k.confidence >= c.minConfidence && k.tempoBpm >= MIN_TEMPO_BPM
    && k.tempoBpm <= MAX_TEMPO_BPM && inUnit(k.beatPhase) && inUnit(k.barPhase);
  return confident ? 60 / k.tempoBpm : null;
}

// The first boundary request + (k - phase) * period at or after earliest.
function nextBoundary(request, earliest, phase, period) {
  const k = Math.ceil((earliest - request) / period + phase);
  const at = request + (k - phase) * period;
  return at < earliest ? earliest : at;
}

const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);

/** A clock is { timeSeconds, beatPhase, barPhase, tempoBpm, confidence }; a
 * status is { progress, requestSeconds, startSeconds, endSeconds, state,
 * quantise, autoRequested }. Methods that take an `out` status fill it in
 * place, so the per-frame path allocates nothing; refused calls return false
 * and leave `out` as it was. */
export class TransitionScheduler {
  constructor(config = {}) {
    const c = { ...DEFAULT_CONFIG, ...config };
    if (!validConfig(c)) throw new RangeError('transition configuration out of range');
    this.config = Object.freeze(c);
    this.scheduled = false;
    this.request_ = 0; this.earliest = 0; this.start = 0; this.end = 0; this.quantise = 0;
    this.anchor = null;
  }

  static status() {
    return { progress: 0, requestSeconds: 0, startSeconds: 0, endSeconds: 0, state: 0, quantise: 0, autoRequested: 0 };
  }

  reset() { this.scheduled = false; this.anchor = null; }

  request(clock, quantise, maxWaitSeconds, out) {
    if (!Number.isFinite(clock.timeSeconds) || !(quantise >= 0 && quantise <= QUANTISE_BAR)
      || Number.isNaN(maxWaitSeconds) || maxWaitSeconds < 0) return false;
    const c = this.config, request = clock.timeSeconds, earliest = request + c.preRollSeconds;
    const beat = beatPeriod(c, clock);
    let start = earliest, applied = QUANTISE_NONE, duration = c.fallbackSeconds;
    if (beat !== null) {
      if (quantise === QUANTISE_BAR) {
        const at = nextBoundary(request, earliest, clock.barPhase, beat * c.beatsPerBar);
        if (at - earliest <= maxWaitSeconds) { start = at; applied = QUANTISE_BAR; }
      }
      if (quantise !== QUANTISE_NONE && applied === QUANTISE_NONE) {
        const at = nextBoundary(request, earliest, clock.beatPhase, beat);
        if (at - earliest <= maxWaitSeconds) { start = at; applied = QUANTISE_BEAT; }
      }
      duration = clamp(c.durationBeats * beat, MIN_DURATION_SECONDS, MAX_DURATION_SECONDS);
    }
    this.scheduled = true;
    this.request_ = request; this.earliest = earliest; this.start = start; this.end = start + duration;
    this.quantise = applied;
    this.anchor = null;
    this.statusAt(request, 0, out);
    return true;
  }

  progress(t) {
    if (!this.scheduled || Number.isNaN(t) || t <= this.start) return 0;
    if (t >= this.end) return 1;
    const u = clamp((t - this.start) / (this.end - this.start), 0, 1);
    return this.config.easing === EASING_SMOOTHSTEP ? u * u * (3 - 2 * u) : u;
  }

  update(clock, out) {
    const t = clock.timeSeconds;
    if (!Number.isFinite(t)) return false;
    const c = this.config;
    if (c.autoAdvanceBars > 0 && (!this.scheduled || t >= this.end)) {
      if (this.anchor === null) this.anchor = this.scheduled ? this.end : t;
      const beat = beatPeriod(c, clock);
      const bar = (beat === null ? 60 / FALLBACK_TEMPO_BPM : beat) * c.beatsPerBar;
      if (t - this.anchor >= c.autoAdvanceBars * bar) {
        this.request(clock, QUANTISE_BAR, bar, out);
        this.statusAt(t, 1, out);
        return true;
      }
    }
    this.statusAt(t, 0, out);
    return true;
  }

  status(t, out) { this.statusAt(t, 0, out); return true; }

  statusAt(t, autoRequested, out) {
    out.autoRequested = autoRequested;
    if (!this.scheduled) {
      out.progress = 0; out.requestSeconds = 0; out.startSeconds = 0; out.endSeconds = 0;
      out.state = STATE_IDLE; out.quantise = 0;
      return;
    }
    out.state = t >= this.end ? STATE_DONE : t >= this.start ? STATE_BLENDING
      : t >= this.earliest ? STATE_WAITING : STATE_PRE_ROLL;
    out.progress = this.progress(t);
    out.requestSeconds = this.request_; out.startSeconds = this.start; out.endSeconds = this.end;
    out.quantise = this.quantise;
  }
}

/** The host side of a switch: one scheduler at the default configuration
 * (linear progress: the transition shaders ease themselves), its beat clock
 * and its status, all allocated once. The host fills `clock` from the visible
 * music, calls request() when a switch begins and frame(t) on every frame of
 * it. Renderer.swift uses the TransitionDirector of TransitionDirector.swift. */
export class TransitionDirector {
  constructor(quantise = QUANTISE_BAR) {
    this.scheduler = new TransitionScheduler();
    this.quantise = quantise;
    this.clock = { timeSeconds: 0, beatPhase: 0, barPhase: 0, tempoBpm: 0, confidence: 0 };
    this.status = TransitionScheduler.status();
  }

  // Schedules a switch from `clock`: on the next bar or beat after the
  // pre-roll, waiting at most one bar, or at once without a confident beat.
  request() {
    const bar = this.scheduler.config.beatsPerBar * 60 / this.clock.tempoBpm;
    return this.scheduler.request(this.clock, this.quantise, bar > 0 && bar < Infinity ? bar : 0, this.status);
  }

  // The blend progress at presentation time t; this.status holds the state.
  frame(t) {
    this.scheduler.status(t, this.status);
    return this.status.progress;
  }

  reset() { this.scheduler.reset(); this.scheduler.status(0, this.status); }
}
