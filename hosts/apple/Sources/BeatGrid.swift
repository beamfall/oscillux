// SPDX-License-Identifier: AGPL-3.0-only
// The Oscillux offline beat and downbeat grid (oscillux_beatgrid_*) of a whole
// decoded file. Construction runs the analysis, which allocates and takes about a second per
// four minutes of audio, so build it off the main thread; clock(at:) does not allocate.
import Foundation

final class BeatGrid {
    /// The musical position at one media time (OscilluxBeatGridClock).
    struct Clock {
        var beatPhase = 0.0, barPhase = 0.0, bpm = 0.0
        /// Negative before the first beat and at or beyond `beatCount` after the last, where the
        /// grid is extrapolated at its first and last interval.
        var beatIndex = -1, beatInBar = 0
        /// False without a position: a grid of fewer than two beats or a non-finite time.
        var hasPosition: Bool { bpm > 0 }
    }

    let beatCount: Int
    let bpm: Double, confidence: Double, beatsPerBar: Int
    private let handle: OpaquePointer

    /// Analyses interleaved float PCM, `channels` samples per frame, at `sampleRate` Hz.
    init(interleaved samples: [Float], channels: Int, sampleRate: Double) throws {
        var cfg = OscilluxBeatGridConfig()
        cfg.struct_size = UInt32(MemoryLayout<OscilluxBeatGridConfig>.size)
        guard oscillux_beatgrid_config_default(&cfg) == OSCILLUX_OK else { throw BeatGridError("config default failed") }
        cfg.sample_rate_hz = UInt32(sampleRate.rounded())
        cfg.channels = UInt32(channels)
        var field: UnsafePointer<CChar>?
        guard channels > 0, oscillux_beatgrid_config_validate(&cfg, &field) == OSCILLUX_OK else {
            throw BeatGridError("beat grid refused \(field.map { String(cString: $0) } ?? "channels") at \(sampleRate) Hz")
        }
        var grid: OpaquePointer?
        let status = samples.withUnsafeBufferPointer { s in
            oscillux_beatgrid_create(&cfg, s.baseAddress, s.count / channels, &grid)
        }
        guard status == OSCILLUX_OK, let grid else { throw BeatGridError("beat grid failed: status \(status)") }
        handle = grid
        var info = OscilluxBeatGridInfo()
        _ = oscillux_beatgrid_info(grid, &info)
        beatCount = Int(info.beat_count)
        bpm = info.tempo_bpm
        confidence = info.confidence
        beatsPerBar = Int(info.beats_per_bar)
    }

    deinit { oscillux_beatgrid_destroy(handle) }

    /// The position at `mediaTime` seconds from the start of the analysed PCM.
    func clock(at mediaTime: Double) -> Clock {
        var c = OscilluxBeatGridClock()
        _ = oscillux_beatgrid_clock(handle, mediaTime, &c)
        return Clock(beatPhase: c.beat_phase, barPhase: c.bar_phase, bpm: c.tempo_bpm,
                     beatIndex: Int(c.beat_index), beatInBar: Int(c.beat_in_bar))
    }
}

struct BeatGridError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
