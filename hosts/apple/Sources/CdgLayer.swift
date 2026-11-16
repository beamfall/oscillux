// SPDX-License-Identifier: AGPL-3.0-only
// CD+G lyrics over the visual (OSC-CDG), as hosts/web/cdg.js: the core's decoder,
// advanced to the audio's media time each stepped frame, and its 288 x 192 window copied to the
// lyric present pass's layer texture (shaders/cdg/cdg-layer.glsl) only when it changed. The
// transparency key is host data: auto by default, which keys the colours of the window's edge.
import Foundation
import Metal

/// A transparency key from -cdgkey: auto, none, table, preset, index:N (N 0..15) or mask:HHHH
/// (a 16-bit hex mask); anything else is auto.
struct CdgKey: Equatable {
    /// The auto rule (hosts/README.md, as autoMask in hosts/web/cdg.js): the edge's commonest
    /// index, plus each next commonest that covers at least 1/autoShare of the edge, autoMax
    /// indices at most.
    static let autoShare: UInt32 = 8, autoMax = 3
    var auto = true
    var mode = UInt32(OSCILLUX_CDG_KEY_MASK)
    var index: UInt32 = 0

    init(_ text: String?) {
        switch text {
        case "none": set(OSCILLUX_CDG_KEY_NONE)
        case "table": set(OSCILLUX_CDG_KEY_TRANSPARENT_TABLE)
        case "preset": set(OSCILLUX_CDG_KEY_PRESET_COLOUR)
        case let t? where t.hasPrefix("index:"):
            if let n = UInt32(t.dropFirst(6)), n < 16 { set(OSCILLUX_CDG_KEY_INDEX, n) }
        case let t? where t.hasPrefix("mask:"):
            if t.count <= 9, let m = UInt32(t.dropFirst(5), radix: 16) { set(OSCILLUX_CDG_KEY_MASK, m) }
        default: break
        }
    }

    private mutating func set<Mode: BinaryInteger>(_ mode: Mode, _ index: UInt32 = 0) {
        auto = false
        self.mode = UInt32(mode)
        self.index = index
    }

    /// The auto key's mask for 16 per-index pixel counts of the window's edge ring.
    static func autoMask(_ counts: [UInt32]) -> UInt32 {
        let total = counts.reduce(0, +)
        let order = counts.indices.sorted { counts[$0] != counts[$1] ? counts[$0] > counts[$1] : $0 < $1 }
        var mask: UInt32 = 1 << order[0]
        for i in order.dropFirst().prefix(autoMax - 1) where counts[i] > 0 && counts[i] * autoShare >= total {
            mask |= 1 << i
        }
        return mask
    }
}

/// A loaded .cdg file: the core's decoder over its packs.
final class CdgStream {
    let name: String
    fileprivate let handle: OpaquePointer

    convenience init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url), name: url.lastPathComponent)
    }

    /// A stream from bytes already read, such as a .cdg taken from a karaoke .zip.
    init(data: Data, name: String) throws {
        var out: OpaquePointer?
        let status = data.withUnsafeBytes {
            oscillux_cdg_create($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &out)
        }
        guard status == OSCILLUX_OK, let out else {
            throw ReactionError("\(name): not a CD+G stream (status \(status))")
        }
        handle = out
        self.name = name
    }

    /// The decoder key for the window as it stands: `key`, or for auto the mask of its edge.
    func resolve(_ key: CdgKey) -> (mode: UInt32, index: UInt32) {
        guard key.auto else { return (key.mode, key.index) }
        var counts = [UInt32](repeating: 0, count: Int(OSCILLUX_CDG_INDEX_COUNT))
        guard oscillux_cdg_index_counts(handle, UInt32(OSCILLUX_CDG_REGION_EDGE), &counts, counts.count) == OSCILLUX_OK else {
            return (UInt32(OSCILLUX_CDG_KEY_PRESET_COLOUR), 0)
        }
        return (UInt32(OSCILLUX_CDG_KEY_MASK), CdgKey.autoMask(counts))
    }

    deinit { oscillux_cdg_destroy(handle) }
}

/// The lyric layer: the shown stream's window in a private texture. A change is written to a
/// staging buffer that the frame's command buffer copies into the texture, so the GPU never
/// reads a texture the CPU is writing; a staging buffer is reused once the copy from it has
/// completed, and a change waits a frame when both are still in flight.
final class CdgLayer {
    static let width = Int(OSCILLUX_CDG_WINDOW_WIDTH), height = Int(OSCILLUX_CDG_WINDOW_HEIGHT)
    static let bytes = Int(OSCILLUX_CDG_WINDOW_RGBA_BYTES)
    let texture: MTLTexture
    private let staging: [MTLBuffer]
    private var free: [Bool]
    private var shown: ObjectIdentifier?
    private var shownKey = CdgKey(nil)
    private var dirty = true
    private var lastApplied: UInt64 = 0
    private var state = OscilluxCdgState()

    init?(_ device: MTLDevice) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: CdgLayer.width,
                                                            height: CdgLayer.height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .private
        let buffers = (0..<2).compactMap { _ in device.makeBuffer(length: CdgLayer.bytes, options: .storageModeShared) }
        guard let texture = device.makeTexture(descriptor: desc), buffers.count == 2 else { return nil }
        self.texture = texture
        staging = buffers
        free = [true, true]
    }

    /// Advances `stream` to media time `ms` (nil holds its position) and, when the window
    /// changed, copies it into the texture in `command`. Returns the packs applied. An advance
    /// to the time already shown applies nothing, so a held position copies nothing.
    @discardableResult
    func update(_ stream: CdgStream, key: CdgKey, ms: Double?, _ command: MTLCommandBuffer) -> UInt64 {
        let id = ObjectIdentifier(stream)
        if shown != id || shownKey != key { shown = id; shownKey = key; dirty = true }
        var advanced = false
        if let ms, ms.isFinite {
            advanced = oscillux_cdg_advance_to_time(stream.handle, max(ms, 0) / 1000) == OSCILLUX_OK
            if !advanced { NSLog("cdg: advance refused") }
        }
        state.struct_size = UInt32(MemoryLayout<OscilluxCdgState>.size)
        guard oscillux_cdg_state(stream.handle, &state) == OSCILLUX_OK else { return lastApplied }
        let applied = state.applied
        // the change bits describe the last advance, so they count only after one; a seek back
        // restores a checkpoint, which reports the whole screen as changed
        if advanced && (state.changes != 0 || applied < lastApplied) { dirty = true }
        lastApplied = applied
        guard dirty, let slot = free.firstIndex(of: true) else { return applied }
        let buffer = staging[slot]
        let resolved = stream.resolve(key)
        guard oscillux_cdg_window_rgba(stream.handle, resolved.mode, resolved.index,
                                       buffer.contents().assumingMemoryBound(to: UInt8.self), CdgLayer.bytes) == OSCILLUX_OK,
              let blit = command.makeBlitCommandEncoder() else { return applied }
        blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: CdgLayer.width * 4,
                  sourceBytesPerImage: CdgLayer.bytes, sourceSize: MTLSize(width: CdgLayer.width, height: CdgLayer.height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        free[slot] = false
        command.addCompletedHandler { [weak self] _ in DispatchQueue.main.async { self?.free[slot] = true } }
        dirty = false
        return applied
    }
}
