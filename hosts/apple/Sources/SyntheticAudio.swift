// SPDX-License-Identifier: AGPL-3.0-only
// Line-for-line port of tools/shader/synthetic-audio.mjs syntheticPcm, in Double
// like the JavaScript original, so every host analyses the same samples:
// SyntheticPCM is what the Apple and web hosts run through the core
// (Reaction.swift).
import Foundation

/// The audio inputs the visual uniforms read: the reaction sampler's values
/// (Reaction.swift).
protocol AudioFeatures {
    var amplitude: Double { get }
    var bass: Double { get }
    var mid: Double { get }
    var treble: Double { get }
    var beat: Double { get }
    var beatPhase: Double { get }
    var onset: Double { get }
    var bassImpact: Double { get }
    var level: Double { get }
    var spectralCentroid: Double { get }
    var flux: Double { get }
    var beatCount: Double { get }
    var barPhase: Double { get }
    var downbeat: Double { get }
    /// Spectrum bin `i` of 64.
    func spectrum(_ i: Int) -> Double
}

/// syntheticPcm: one loop of 8 bars of 4/4 at 125 BPM, 48 kHz mono. Every
/// operation is the JavaScript one in the same order, each rounded once, so the
/// samples are bit-identical (sha256 56bf06b2… of the little-endian floats).
enum SyntheticPCM {
    static let rate = 48000
    static let beat = 23040
    static let loop = 32 * beat
    /// One loop of samples, built on first use.
    static let samples: [Float] = build()

    /// n samples of a sine whose 2cos(w) is c2 and sin(w) is s1, times a decay
    /// envelope (each sample multiplies it by k) from amplitude a.
    private static func tone(_ n: Int, _ c2: Double, _ s1: Double, _ k: Double, _ a: Double) -> [Double] {
        var out = [Double](repeating: 0, count: n)
        var y0 = 0.0, y1 = s1, e = a
        for i in 0..<n {
            out[i] = y0 * e
            let y2 = c2 * y1 - y0
            y0 = y1; y1 = y2; e = e * k
        }
        return out
    }

    private static func build() -> [Float] {
        let BEAT = beat, HALF = beat / 2, BAR = 4 * beat
        var x: UInt32 = 0x9e37_79b9
        func noise() -> Double {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            return Double(x) * 4.656612873077393e-10 - 1
        }
        var kick = tone(BEAT, 1.9999536678693404, 0.006806731520561792, 0.9998264039584257, 0.6)
        for i in 0..<240 { kick[i] = kick[i] + noise() * (1 - Double(i) / 240) * 0.3 }
        var hat = [Double](repeating: 0, count: HALF)
        var prev = 0.0, e = 1.0
        for i in 0..<HALF {
            let v = noise()
            hat[i] = (v - prev) * e
            prev = v; e = e * 0.9991670137924583
        }
        func bassNote(_ c1: Double, _ s1: Double, _ c2: Double, _ s2: Double) -> [Double] {
            var a = tone(HALF, c1, s1, 0.9998611207557263, 0.5)
            let b = tone(HALF, c2, s2, 0.9998611207557263, 0.25)
            for i in 0..<HALF { a[i] = (a[i] + b[i]) * (i < 480 ? Double(i) / 480 : 1) }
            return a
        }
        let bass = [bassNote(1.9999481676660484, 0.00719942097003321, 1.999792673350785, 0.014398468777274444),
                    bassNote(1.9999076455921194, 0.009610009133520078, 1.9996305908978147, 0.019219130740336904)]
        func chord(_ notes: [(Double, Double)]) -> [Double] {
            var out = [Double](repeating: 0, count: BAR)
            for (c2, s1) in notes {
                let t = tone(BAR, c2, s1, 1, 1.0 / 3)
                for i in 0..<BAR { out[i] = out[i] + t[i] }
            }
            for i in 0..<BAR { out[i] = out[i] * min(1, Double(i) / 9600) * min(1, Double(BAR - i) / 9600) }
            return out
        }
        let pad = [chord([(1.9991707363874793, 0.02879395236826347), (1.9988272777241678, 0.034240012506541136),
                          (1.9981385262995264, 0.04313475894669265)]),
                   chord([(1.999477583299356, 0.022854944122476323), (1.9991707363874793, 0.02879395236826347),
                          (1.9988272777241678, 0.034240012506541136)])]
        var out = [Float](repeating: 0, count: loop)
        for n in 0..<loop {
            let bar = n / BAR, b = n / BEAT, j = n - b * BEAT
            var s = (b % 4 == 0 ? 0.9 : 0.6) * kick[j]
            if j >= HALF { s = s + (bar >= 4 ? 0.2 : 0.12) * hat[j - HALF] + 0.3 * bass[bar & 1][j - HALF] }
            s = s + 0.1 * pad[bar & 1][n - bar * BAR]
            out[n] = Float(s)
        }
        return out
    }
}
