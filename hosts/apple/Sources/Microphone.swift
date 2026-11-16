// SPDX-License-Identifier: AGPL-3.0-only
// The microphone as an audio source, as hosts/web/audio.js MicSource: the input's first channel
// through DSP v4, the mapper and the reaction sampler on the host clock (seconds as
// CACurrentMediaTime counts them), never played back. An input tap copies each buffer, with
// the host time of its first sample, into chunks of a ring allocated up front; each stepped
// frame drains the ring into the analyser and samples at the photon time, so values appear as
// soon as they are analysed. Lost input (a full ring, a gap in the tap's timestamps) starts a
// stalled segment at the next chunk. Opening allocates; frame() and the tap do not.
import AVFoundation
import QuartzCore
import Synchronization

final class MicSource {
    private static let chunks = 32, chunkFrames = 4096 // ring of about 2.7 s at 48 kHz
    let name = "microphone"
    private let engine = AVAudioEngine()
    private let rate: Double
    private let analyzer: Analyzer
    private var sampler: ReactionSampler
    // The ring: chunk i holds counts[i] samples from samples + i * chunkFrames, the first at
    // host time starts[i] (ms). The tap publishes a chunk by advancing `written`, frame()
    // frees it by advancing `read`; each index has one writer.
    private let samples: UnsafeMutablePointer<Float>
    private let starts: UnsafeMutablePointer<Double>
    private let counts: UnsafeMutablePointer<Int>
    private let written = Atomic<Int>(0), read = Atomic<Int>(0)
    /// Set by the tap when it dropped input; frame() starts a stalled segment after it.
    private let dropped = Atomic<Bool>(false)
    /// The media time the next drained sample should carry, or nil before the first.
    private var expected: Double?
    private var last = -Double.infinity

    /// Starts capture; the caller has the record permission.
    init() throws {
        #if os(iOS)
        // measurement mode: no echo cancellation, noise suppression or gain control, as the web
        // host asks getUserMedia for
        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ReactionError("no microphone input") }
        rate = format.sampleRate
        analyzer = try Analyzer(rate: rate, channels: 1)
        sampler = try ReactionSampler(rate: rate, outputLatencyMs: 0)
        samples = .allocate(capacity: MicSource.chunks * MicSource.chunkFrames)
        samples.initialize(repeating: 0, count: MicSource.chunks * MicSource.chunkFrames)
        starts = .allocate(capacity: MicSource.chunks)
        starts.initialize(repeating: 0, count: MicSource.chunks)
        counts = .allocate(capacity: MicSource.chunks)
        counts.initialize(repeating: 0, count: MicSource.chunks)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [unowned self] buffer, when in
            capture(buffer, when)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    deinit {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        samples.deallocate()
        starts.deallocate()
        counts.deallocate()
    }

    /// The values of the last frame, for the status line.
    var latest: ReactionAudio { sampler.latest }

    /// The tap: the first channel of `buffer`, split into ring chunks.
    private func capture(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0], when.isHostTimeValid else { return }
        let n = Int(buffer.frameLength)
        let startMs = AVAudioTime.seconds(forHostTime: when.hostTime) * 1000
        var done = 0, w = written.load(ordering: .relaxed)
        while done < n {
            guard w - read.load(ordering: .acquiring) < MicSource.chunks else {
                dropped.store(true, ordering: .releasing)
                break
            }
            let slot = w % MicSource.chunks, count = min(n - done, MicSource.chunkFrames)
            (samples + slot * MicSource.chunkFrames).update(from: channel + done, count: count)
            starts[slot] = startMs + Double(done) * 1000 / rate
            counts[slot] = count
            done += count
            w += 1
            written.store(w, ordering: .releasing)
        }
    }

    /// The values seen at host time `photon` (seconds). Input never plays, so the latest time
    /// analysed is the latest heard; the sampler holds the time it reached when input stops.
    func frame(photon: Double) -> ReactionAudio {
        let w = written.load(ordering: .acquiring)
        var r = read.load(ordering: .relaxed)
        while r < w {
            let slot = r % MicSource.chunks, start = starts[slot], count = counts[slot]
            // a jump of more than a few ms is lost input: the tap's buffers are back to back
            let gap = expected.map { abs(start - $0) > 5 } ?? true
            if gap || dropped.exchange(false, ordering: .acquiringAndReleasing) {
                try? analyzer.beginSegment(start, stalled: expected != nil)
            }
            let s = sampler
            _ = try? analyzer.feed(samples + slot * MicSource.chunkFrames, count) { m, mapped, beat in
                s.push(m, mapped, beat)
            }
            expected = start + Double(count) * 1000 / rate
            r += 1
            read.store(r, ordering: .releasing)
        }
        // never earlier than the last sample, which would resync the beat
        last = max(last, photon * 1000)
        return sampler.sample(last)
    }
}
