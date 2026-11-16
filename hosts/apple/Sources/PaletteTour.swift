// SPDX-License-Identifier: AGPL-3.0-only
// Port of tools/shader/palette-tour.mjs, in Double precision: the "vivid"
// colour mode's free-mode palette tour and present-pass saturation.
enum PaletteTour {
    static let count = 16.0
    static let seconds = 6.0
    static let vividSaturation: Float = 1.35
    static let vividVibrance: Float = 1.2

    static func palette(at time: Double, offset: Double) -> [Float] {
        let z = ((time / seconds + offset).truncatingRemainder(dividingBy: count) + count).truncatingRemainder(dividingBy: count)
        return [-1, 0, Float(z), 0]
    }
}
