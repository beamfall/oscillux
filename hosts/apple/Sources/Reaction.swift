// SPDX-License-Identifier: AGPL-3.0-only
// The audio values of every frame come from the Oscillux reaction
// sampler (oscillux_reaction_*), fed mapped DSP hops with their tracker output
// and sampled once per stepped frame, as hosts/web/audio.js does. Sources:
// - SyntheticSource: SyntheticPCM through DSP v4, the mapper and the sampler on
//   the host's 1/60 s step clock with no latency, so a capture is deterministic
//   and matches the web host;
// - AudioTrack.swift: a file, sampled at the display link's target presentation
//   time with the engine's output latency;
// - Microphone.swift: the live input, on the host clock, never played back.
// Creation allocates; frame() and the pushes and samples behind it do not.
import Foundation

/// One frame's values from the sampler, as the visual uniforms read them.
struct ReactionAudio: AudioFeatures {
    var r = OscilluxReaction()

    var amplitude: Double { r.mapped.values.0 }
    var level: Double { r.mapped.values.1 }
    var bass: Double { r.mapped.values.2 }
    var mid: Double { r.mapped.values.3 }
    var treble: Double { r.mapped.values.4 }
    var onset: Double { r.mapped.values.5 }
    var bassImpact: Double { r.mapped.values.6 }
    var flux: Double { r.mapped.values.7 }
    var spectralCentroid: Double { r.mapped.values.8 }
    var beat: Double { r.beat }
    var downbeat: Double { r.downbeat }
    var beatPhase: Double { r.beat_phase }
    var barPhase: Double { r.bar_phase }
    var beatCount: Double { Double(r.beat_count) }
    var tempo: Double { r.tempo_bpm }
    var confidence: Double { r.confidence }
    var beatInBar: Int { Int(r.beat_in_bar) }
    var locked: Bool { r.locked != 0 }

    func spectrum(_ i: Int) -> Double {
        withUnsafeBytes(of: r.mapped.spectrum) { Double($0.load(fromByteOffset: i * 4, as: Float.self)) }
    }
}

struct ReactionError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func checkOscillux(_ status: Int32, _ what: String) throws {
    guard status == OSCILLUX_OK else { throw ReactionError("Oscillux \(what) failed: status \(status)") }
}

/// The reaction sampler at DSP version 4's latencies for `rate`.
final class ReactionSampler {
    static let capacity: UInt32 = 1024 // queued hops, about 11 s at 48 kHz
    let outputLatencyMs: Double
    let analysisLatencyMs: Double
    private var handle: OpaquePointer?
    private(set) var latest = ReactionAudio()
    /// Media time of the last hop pushed.
    private(set) var lastM = -Double.infinity

    init(rate: Double, outputLatencyMs: Double) throws {
        var rc = OscilluxReactionConfig()
        rc.struct_size = UInt32(MemoryLayout<OscilluxReactionConfig>.size)
        try checkOscillux(oscillux_reaction_config_default(UInt32(OSCILLUX_DSP_BEHAVIOR_V4), UInt32(rate.rounded()), &rc),
                          "reaction config")
        rc.capacity = ReactionSampler.capacity
        rc.output_latency_ms = max(0, outputLatencyMs)
        self.outputLatencyMs = rc.output_latency_ms
        analysisLatencyMs = rc.analysis_latency_ms
        try checkOscillux(oscillux_reaction_create(&rc, &handle), "reaction create")
    }

    deinit { oscillux_reaction_destroy(handle) }

    /// Queues a hop; a full queue (no samples for a long time) starts the sampler over.
    func push(_ m: Double, _ mapped: UnsafePointer<OscilluxMapped>, _ beat: UnsafePointer<OscilluxDspBeat>?) {
        if oscillux_reaction_push(handle, m, mapped, beat) != OSCILLUX_OK {
            oscillux_reaction_reset(handle)
            guard oscillux_reaction_push(handle, m, mapped, beat) == OSCILLUX_OK else { return }
        }
        lastM = m
    }

    /// The values seen at the photon time of a frame sampled at media time `time` (ms).
    @discardableResult
    func sample(_ time: Double) -> ReactionAudio {
        _ = oscillux_reaction_sample(handle, time, &latest.r)
        return latest
    }

    func reset() {
        oscillux_reaction_reset(handle)
        lastM = -.infinity
    }

    /// Drives the beat outputs from a host beat clock (an offline beat grid), or
    /// nil for the tracker output pushed with the hops.
    func setBeatClock(_ clock: OscilluxBeatClock?) -> Bool {
        guard var c = clock else { return oscillux_reaction_set_beat_clock(handle, nil) == OSCILLUX_OK }
        return oscillux_reaction_set_beat_clock(handle, &c) == OSCILLUX_OK
    }
}

/// DSP v4 and the mapper with relative levels for `channels` interleaved
/// channels at `rate`: the analysis every source shares.
final class Analyzer {
    static let chunk = 4096 // sample frames per DSP push
    let channels: Int
    var config = OscilluxDspVersionedConfig()
    private var dsp: OpaquePointer?
    private var mapper: OpaquePointer?
    private let cap: Int
    private let frames: UnsafeMutablePointer<OscilluxDspFrame>
    private let ext: UnsafeMutablePointer<OscilluxDspFrameExt>
    private var mapped = OscilluxMapped()

    init(rate: Double, channels: Int, startMs: Double = 0) throws {
        self.channels = channels
        config.struct_size = UInt32(MemoryLayout<OscilluxDspVersionedConfig>.size)
        try checkOscillux(oscillux_dsp_versioned_config_default(&config), "config default")
        config.behavior_version = OSCILLUX_DSP_BEHAVIOR_V4
        config.config.sample_rate_hz = UInt32(rate.rounded())
        config.config.spectrum_max_hz = min(config.config.spectrum_max_hz, rate / 2)
        var field: UnsafePointer<CChar>?
        guard oscillux_dsp_versioned_config_validate(&config, &field) == OSCILLUX_OK else {
            throw ReactionError("DSP refused \(field.map { String(cString: $0) } ?? "config") at \(rate) Hz")
        }
        cap = Analyzer.chunk / Int(config.config.hop_samples) + 2
        frames = .allocate(capacity: cap)
        frames.initialize(repeating: OscilluxDspFrame(), count: cap)
        var blank = OscilluxDspFrameExt()
        blank.struct_size = UInt32(MemoryLayout<OscilluxDspFrameExt>.size)
        ext = .allocate(capacity: cap)
        ext.initialize(repeating: blank, count: cap)
        try checkOscillux(oscillux_dsp_create_versioned(&config, &dsp), "DSP create")
        try checkOscillux(oscillux_dsp_begin_segment(dsp, startMs, 0), "DSP begin segment")
        var mc = OscilluxMappingConfig()
        try checkOscillux(oscillux_mapping_config_from_dsp(&config.config, &mc), "mapping config")
        try checkOscillux(oscillux_mapping_create(&mc, &mapper), "mapping create")
        try checkOscillux(oscillux_mapping_set_level_source(mapper, OSCILLUX_MAPPING_LEVELS_RELATIVE), "level source")
    }

    deinit {
        oscillux_mapping_destroy(mapper)
        oscillux_dsp_destroy(dsp)
        frames.deallocate()
        ext.deallocate()
    }

    var hopMs: Double { Double(config.config.hop_samples) * 1000 / Double(config.config.sample_rate_hz) }

    /// The next sample fed plays at media time `ms`; `stalled` when input was lost before it.
    func beginSegment(_ ms: Double, stalled: Bool) throws {
        try checkOscillux(oscillux_dsp_begin_segment(dsp, ms, stalled ? 1 : 0), "DSP begin segment")
    }

    /// Analyses `count` interleaved frames from `src` and hands every hop's media
    /// time, mapped values and tracker output to `hop`.
    func feed(_ src: UnsafePointer<Float>, _ count: Int,
              _ hop: (Double, UnsafePointer<OscilluxMapped>, UnsafePointer<OscilluxDspBeat>) -> Void) throws {
        var done = 0
        while done < count {
            var result = OscilluxDspPushResult()
            try checkOscillux(oscillux_dsp_push_ext_f32(dsp, src + done * channels, min(count - done, Analyzer.chunk),
                                                        UInt32(channels), frames, ext, cap, &result), "DSP push")
            for k in 0..<result.produced {
                try checkOscillux(oscillux_mapping_process_ext(mapper, frames + k, ext + k, 0, &mapped), "mapping")
                withUnsafePointer(to: &ext[k].beat) { beat in hop(frames[k].media_time_ms, &mapped, beat) }
            }
            guard result.consumed > 0 else { throw ReactionError("the DSP consumed nothing") }
            done += result.consumed
        }
    }
}

/// SyntheticPCM on the step clock: frame k samples at k/60 s. The analyser first
/// runs one loop that the sampler does not see (it warms the tracker and the
/// level envelopes), so the step clock's 0 is the start of the second loop.
final class SyntheticSource {
    private static let loopMs = Double(SyntheticPCM.loop) * 1000 / Double(SyntheticPCM.rate)
    private let pcm = SyntheticPCM.samples
    private var analyzer: Analyzer
    private var sampler: ReactionSampler
    private var fed = 0
    private(set) var steps = 0
    /// The media time of the last sampled step within the loop, ms.
    var mediaMs: Double { (Double(steps - 1) * 1000 / 60).truncatingRemainder(dividingBy: SyntheticSource.loopMs) }

    init() throws {
        (analyzer, sampler) = try SyntheticSource.preroll(pcm)
        fed = SyntheticPCM.loop
    }

    private static func preroll(_ pcm: [Float]) throws -> (Analyzer, ReactionSampler) {
        let rate = Double(SyntheticPCM.rate)
        let a = try Analyzer(rate: rate, channels: 1), s = try ReactionSampler(rate: rate, outputLatencyMs: 0)
        try pcm.withUnsafeBufferPointer { p in
            try a.feed(p.baseAddress!, p.count) { m, mapped, beat in
                if m - loopMs >= -50 { s.push(m - loopMs, mapped, beat) }
            }
        }
        return (a, s)
    }

    /// Back to step 0 with a freshly warmed analysis.
    func restart() {
        guard let fresh = try? SyntheticSource.preroll(pcm) else { return }
        (analyzer, sampler) = fresh
        fed = SyntheticPCM.loop
        steps = 0
    }

    /// Feeds hops until the sampler holds the one after this step's time, then samples there.
    func frame() -> ReactionAudio {
        let t = Double(steps) * 1000 / 60
        steps += 1
        let s = sampler, loopMs = SyntheticSource.loopMs
        while s.lastM - s.analysisLatencyMs <= t {
            let at = fed % SyntheticPCM.loop
            let ok = pcm.withUnsafeBufferPointer { p in
                (try? analyzer.feed(p.baseAddress! + at, 512) { m, mapped, beat in s.push(m - loopMs, mapped, beat) }) != nil
            }
            fed += 512
            guard ok else { break }
        }
        return s.sample(t)
    }
}
