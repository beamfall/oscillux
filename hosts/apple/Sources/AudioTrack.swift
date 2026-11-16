// SPDX-License-Identifier: AGPL-3.0-only
// Plays an audio file (FLAC, WAV, AIFF, ALAC, MP3, …) and feeds the
// visuals Oscillux DSP analysis of it in place of the synthetic source. The
// whole file is analysed once, offline, at behaviour version 4 (beat tracker)
// and mapped with relative levels, into one hop per row: its media time, mapped
// values and tracker output. The analysis first hears the 30 s of the loop
// before the file's start (its end, repeated if shorter), so every loop starts
// with the tracker and level envelopes warm. The offline beat grid
// (BeatGrid.swift), which hears the whole file, replaces the tracker's beat as
// the sampler's host beat clock. Each frame pushes the rows due by its photon
// time into the reaction sampler (Reaction.swift), sets the grid clock and
// samples it, so the per-frame path only pushes, queries the grid and samples.
import AVFoundation
import QuartzCore

final class AudioTrack {
    /// One analysed hop.
    private struct Hop {
        var m: Double
        var mapped: OscilluxMapped
        var beat: OscilluxDspBeat
    }

    let name: String
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer
    private let duration: Double
    private let rate: Double
    private var rows: [Hop] = []
    private var sampler: ReactionSampler
    /// The offline beat grid of the file, the sampler's host beat clock; nil keeps the v4 tracker beat.
    private var grid: BeatGrid?
    /// Rows pushed so far on the looped timeline: row i of loop k is at
    /// rows[i].m + k * duration.
    private var cursor = 0
    /// The media time of the last sampled frame within the file, ms: what plays at its photon.
    private(set) var lastMediaMs: Double?
    /// Media time (ms, counting on across loops) at the output's write position
    /// at `startedAt` (host seconds), or the paused position.
    private var startMs = 0.0
    private var startedAt: Double?

    /// Decodes and analyses `url`, shown as `name` (its file name by default); call off the main
    /// thread, it reads the whole file.
    init(url: URL, name: String? = nil) throws {
        self.name = name ?? url.lastPathComponent
        #if os(iOS)
        // played out loud, on the speaker with the ring switch on silent too
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ReactionError("cannot allocate \(file.length) frames")
        }
        try file.read(into: buf)
        buffer = buf
        rate = format.sampleRate
        duration = Double(buf.frameLength) / rate
        guard duration > 0 else { throw ReactionError("\(name) holds no audio") }
        sampler = try ReactionSampler(rate: rate, outputLatencyMs: engine.outputNode.presentationLatency * 1000)
        try analyse(buf)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        schedule()
    }

    deinit { engine.stop() }

    var playing: Bool { startedAt != nil }

    /// Playback position, seconds, wrapped to the file (it loops).
    var now: Double { (mediaMs(CACurrentMediaTime()) / 1000).truncatingRemainder(dividingBy: duration) }

    /// The values of the last frame, for the status line.
    var latest: ReactionAudio { sampler.latest }

    private func mediaMs(_ host: Double) -> Double {
        startedAt.map { startMs + max(0, host - $0) * 1000 } ?? startMs
    }

    /// Starts or resumes playback 50 ms from now, so the clock knows when sound starts.
    func play() {
        guard startedAt == nil else { return }
        // the sampler takes the output latency at creation; a changed one starts it over here
        let latency = engine.outputNode.presentationLatency * 1000
        if abs(latency - sampler.outputLatencyMs) > 1, let s = try? ReactionSampler(rate: rate, outputLatencyMs: latency) {
            sampler = s
            seek(startMs)
        }
        let lead = 0.05
        let at = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead))
        player.play(at: at)
        startedAt = CACurrentMediaTime() + lead
    }

    func pause() {
        guard startedAt != nil else { return }
        startMs = mediaMs(CACurrentMediaTime())
        startedAt = nil
        player.pause()
    }

    /// Back to the start of the file, keeping the play/pause state.
    func restart() {
        let wasPlaying = playing
        player.stop()
        startedAt = nil
        startMs = 0
        sampler.reset()
        seek(0)
        schedule()
        if wasPlaying { play() }
    }

    /// The values seen when a frame presented at host time `photon` (seconds) is on screen.
    func frame(photon: Double) -> ReactionAudio {
        let time = mediaMs(photon), t = time - sampler.outputLatencyMs, durationMs = duration * 1000
        // the lyrics follow the position heard at the photon, as the analysis and grid do
        lastMediaMs = max(t, 0).truncatingRemainder(dividingBy: durationMs)
        while sampler.lastM - sampler.analysisLatencyMs <= t {
            let i = cursor % rows.count, m = rows[i].m + Double(cursor / rows.count) * durationMs
            var mapped = rows[i].mapped, beat = rows[i].beat // stack copies: one access to rows each
            sampler.push(m, &mapped, &beat)
            cursor += 1
        }
        if let grid {
            // The grid position of the music heard at the photon time, on the looped timeline.
            let loop = (t / durationMs).rounded(.down), c = grid.clock(at: t / 1000 - loop * duration)
            _ = sampler.setBeatClock(c.hasPosition ? OscilluxBeatClock(
                media_time_ms: t, tempo_bpm: c.bpm, beat_phase: c.beatPhase, bar_phase: c.barPhase,
                beat_index: Int64(c.beatIndex + Int(loop) * grid.beatCount),
                beats_per_bar: UInt32(grid.beatsPerBar), reserved: 0) : nil)
        }
        return sampler.sample(time)
    }

    /// Pushes from the first row at or after `ms - 50` on the looped timeline.
    private func seek(_ ms: Double) {
        let durationMs = duration * 1000, k = max(0, (ms / durationMs).rounded(.down))
        let i = rows.firstIndex { $0.m + k * durationMs >= ms - 50 } ?? rows.count
        cursor = Int(k) * rows.count + i
    }

    private func schedule() {
        player.scheduleBuffer(buffer, at: nil, options: .loops)
    }

    private func analyse(_ buf: AVAudioPCMBuffer) throws {
        // the DSP takes up to two interleaved channels, as hosts/web/audio.js
        let channels = min(2, Int(buf.format.channelCount))
        let frames = Int(buf.frameLength)
        guard let planar = buf.floatChannelData else { throw ReactionError("\(name) is not float PCM") }
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for c in 0..<channels {
            let src = planar[c]
            for i in 0..<frames { interleaved[i * channels + c] = src[i] }
        }
        let analyzer = try Analyzer(rate: rate, channels: channels)
        rows.reserveCapacity(frames / Int(analyzer.config.config.hop_samples) + 1)
        let pre = Int((30 * rate).rounded()), preMs = Double(pre) * 1000 / rate
        let keep = { [self] (m: Double, mapped: UnsafePointer<OscilluxMapped>, beat: UnsafePointer<OscilluxDspBeat>) in
            if m - preMs > 0 { rows.append(Hop(m: m - preMs, mapped: mapped.pointee, beat: beat.pointee)) }
        }
        try interleaved.withUnsafeBufferPointer { s in
            var at = (frames - pre % frames) % frames, left = pre
            while left > 0 {
                let n = min(left, frames - at)
                try analyzer.feed(s.baseAddress! + at * channels, n, keep)
                left -= n
                at = (at + n) % frames
            }
            try analyzer.feed(s.baseAddress!, frames, keep)
        }
        guard !rows.isEmpty else { throw ReactionError("\(name) is shorter than one analysis window") }

        // A grid that is refused or has no position leaves the sampler on the v4 tracker beat.
        do {
            let g = try BeatGrid(interleaved: interleaved, channels: channels, sampleRate: rate)
            if g.clock(at: 0).hasPosition { grid = g }
        } catch {
            NSLog("%@: keeping the v4 tracker beat: %@", name, error.localizedDescription)
        }
    }
}
