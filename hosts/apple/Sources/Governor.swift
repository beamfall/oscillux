// SPDX-License-Identifier: AGPL-3.0-only
// Swift port of tools/shader/governor.mjs (itself a port of
// crates/oscillux-core/src/governor.rs). The three step thresholds can be set;
// the rest is the default configuration. It steps an integer quality level,
// 0 to maxLevel, from frame durations.
struct Governor {
    let targetMs = 1000.0 / 60.0, emaAlpha = 0.1, pauseGapMs = 250.0, sampleCapFactor = 4.0
    let refreshDrift = 1.002, refreshFloorMs = 4.0
    let demoteFactor: Double, promoteRefreshFactor: Double, promoteTargetFactor: Double
    let demoteFrames = 45, promoteFrames = 300, settleFrames = 30
    let maxLevel: Int
    private(set) var level: Int
    private(set) var emaMs: Double?
    private var refreshMs: Double
    private var demote = 0, promote = 0, settle = 0

    init(maxLevel: Int, level: Int, demoteFactor: Double = 1.25,
         promoteRefreshFactor: Double = 1.1, promoteTargetFactor: Double = 0.75) {
        self.demoteFactor = demoteFactor
        self.promoteRefreshFactor = promoteRefreshFactor
        self.promoteTargetFactor = promoteTargetFactor
        self.maxLevel = maxLevel
        self.level = min(level, maxLevel)
        refreshMs = targetMs
    }

    mutating func reset(_ to: Int) {
        level = min(to, maxLevel)
        emaMs = nil
        refreshMs = targetMs
        demote = 0; promote = 0; settle = 0
    }

    mutating func record(_ frameMs: Double) {
        guard frameMs.isFinite, frameMs > 0, frameMs < pauseGapMs else { return }
        let sample = min(frameMs, targetMs * sampleCapFactor)
        refreshMs = max(min(min(refreshMs * refreshDrift, targetMs), sample), refreshFloorMs)
        let ema = emaMs.map { $0 + emaAlpha * (sample - $0) } ?? sample
        emaMs = ema
        if settle > 0 { settle -= 1; return }
        let down = targetMs * demoteFactor
        let up = max(refreshMs * promoteRefreshFactor, targetMs * promoteTargetFactor)
        if ema > down {
            demote += 1; promote = 0
            if demote >= demoteFrames && level > 0 { level -= 1; afterStep() }
        } else if ema < up {
            promote += 1; demote = 0
            if promote >= promoteFrames && level < maxLevel { level += 1; afterStep() }
        } else {
            demote = 0; promote = 0
        }
    }

    private mutating func afterStep() { demote = 0; promote = 0; settle = settleFrames }
}
