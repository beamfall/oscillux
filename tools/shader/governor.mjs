// SPDX-License-Identifier: AGPL-3.0-only
// JavaScript port of crates/oscillux-core/src/governor.rs for the reference
// hosts, checked against conformance/governor by test-governor.mjs. It steps an
// integer quality level from frame durations; the host gives levels a meaning.
export const GOVERNOR_DEFAULTS = Object.freeze({
  targetFrameMs: 1000 / 60, emaAlpha: 0.1, pauseGapMs: 250, sampleCapFactor: 4, refreshDrift: 1.002,
  refreshFloorMs: 4, demoteFactor: 1.25, promoteRefreshFactor: 1.1, promoteTargetFactor: 0.75,
  demoteFrames: 45, promoteFrames: 300, settleFrames: 30, maxLevel: 3, initialLevel: 3,
});

export function validGovernorConfig(c) {
  const positive = [c.targetFrameMs, c.emaAlpha, c.pauseGapMs, c.sampleCapFactor, c.refreshDrift,
    c.refreshFloorMs, c.demoteFactor, c.promoteRefreshFactor, c.promoteTargetFactor];
  const t = c.targetFrameMs;
  const counts = [c.demoteFrames, c.promoteFrames, c.settleFrames, c.maxLevel, c.initialLevel];
  return positive.every(v => Number.isFinite(v) && v > 0)
    && counts.every(v => Number.isInteger(v) && v >= 0)
    && c.emaAlpha <= 1 && c.refreshDrift >= 1 && c.refreshFloorMs <= t
    && c.demoteFrames > 0 && c.promoteFrames > 0 && c.initialLevel <= c.maxLevel
    && [c.sampleCapFactor, c.demoteFactor, c.promoteRefreshFactor, c.promoteTargetFactor]
      .every(v => Number.isFinite(t * v))
    && t * c.promoteRefreshFactor < t * c.demoteFactor
    && t * c.promoteTargetFactor < t * c.demoteFactor;
}

export class Governor {
  constructor(config = {}) {
    const c = { ...GOVERNOR_DEFAULTS, ...config };
    if (!validGovernorConfig(c)) throw new Error('governor: configuration out of range or without hysteresis');
    this.config = c;
    this.reset(c.initialLevel);
  }

  reset(level) {
    const c = this.config;
    this.emaMs = null;
    this.refreshMs = c.targetFrameMs;
    this.level = Math.min(level, c.maxLevel);
    this.demote = 0; this.promote = 0; this.settle = 0;
  }

  record(frameMs) {
    const c = this.config;
    if (!Number.isFinite(frameMs) || frameMs <= 0 || frameMs >= c.pauseGapMs) return this.level;
    const sample = Math.min(frameMs, c.targetFrameMs * c.sampleCapFactor);
    const drifted = Math.min(this.refreshMs * c.refreshDrift, c.targetFrameMs);
    this.refreshMs = Math.max(Math.min(drifted, sample), c.refreshFloorMs);
    this.emaMs = this.emaMs === null ? sample : this.emaMs + c.emaAlpha * (sample - this.emaMs);
    if (this.settle > 0) { this.settle--; return this.level; }
    const down = c.targetFrameMs * c.demoteFactor;
    const up = Math.max(this.refreshMs * c.promoteRefreshFactor, c.targetFrameMs * c.promoteTargetFactor);
    if (this.emaMs > down) {
      this.demote++; this.promote = 0;
      if (this.demote >= c.demoteFrames && this.level > 0) { this.level--; this.afterStep(); }
    } else if (this.emaMs < up) {
      this.promote++; this.demote = 0;
      if (this.promote >= c.promoteFrames && this.level < c.maxLevel) { this.level++; this.afterStep(); }
    } else {
      this.demote = 0; this.promote = 0;
    }
    return this.level;
  }

  afterStep() { this.demote = 0; this.promote = 0; this.settle = this.config.settleFrames; }
}
