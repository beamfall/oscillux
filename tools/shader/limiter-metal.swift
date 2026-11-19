// SPDX-License-Identifier: AGPL-3.0-only
// Runs the frame flash limiter's generated Metal passes (tools/shader/limiter.mjs) for
// limiter-check.mjs --metal. The config (argv[1]) is
//   { passes: [{ function, metal, formats }], cases: [Case], timing: Case? }
// with Case { name, width, height, frames, cols, rows, limit, clock: [[tick, deltaMs, refill]] }.
// Every case's frames arrive on stdin in order as raw RGBA8, top row first; the timing case sends
// two frames that alternate. Per case it prints one JSON line
//   { name, frames: [[holdMask ("0"/"1" per sub-block, row order), grant, deficit, outputDigest,
//     trackDigest]] }
// and for the timing case { timing: { frameMedianMs, passMedianMs: [per pass], frames } } from
// command-buffer GPU timestamps. Prints {"skipped":...} without a unified-memory Metal device.
import Foundation
import Metal

struct Pass: Decodable {
    let function: String
    let metal: String
    let formats: [String]
}

struct Case: Decodable {
    let name: String
    let width: Int
    let height: Int
    let frames: Int
    let cols: Float
    let rows: Float
    let limit: Float
    let clock: [[Float]]
}

struct Config: Decodable {
    let passes: [Pass]
    let cases: [Case]
    let timing: Case?
}

let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
func systemDevice() -> MTLDevice {
    // Readback uses shared textures, which need unified memory.
    guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else {
        print("{\"skipped\":\"no-unified-memory-metal-device\"}")
        exit(0)
    }
    return device
}
let device = systemDevice()
let queue = device.makeCommandQueue()!

let vertex = """

vertex float4 oscillux_limiter_vertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    return float4(p[vid], 0.0, 1.0);
}
"""

func format(_ name: String) -> MTLPixelFormat {
    switch name {
    case "uint32": return .rgba32Uint
    case "uint": return .rgba16Uint
    default: return .rgba8Unorm
    }
}

let pipelines: [MTLRenderPipelineState] = try cfg.passes.map { pass in
    let library = try device.makeLibrary(source: try String(contentsOfFile: pass.metal, encoding: .utf8) + vertex, options: nil)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "oscillux_limiter_vertex")
    desc.fragmentFunction = library.makeFunction(name: pass.function)
    for (i, f) in pass.formats.enumerated() { desc.colorAttachments[i].pixelFormat = format(f) }
    return try device.makeRenderPipelineState(descriptor: desc)
}
let sampler = device.makeSamplerState(descriptor: MTLSamplerDescriptor())!

func texture(_ kind: String, _ w: Int, _ h: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format(kind), width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .renderTarget]
    d.storageMode = .shared
    let t = device.makeTexture(descriptor: d)!
    let row = w * (kind == "uint32" ? 16 : kind == "uint" ? 8 : 4)
    let zero = [UInt8](repeating: 0, count: row * h)
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: zero, bytesPerRow: row)
    return t
}

/// Tracker state cleared to "no state yet" (0, UNTRACKED = 8192, 0, 0) per pixel, the reference
/// model's start (shaders/limiter/common.glsl).
func trackTexture(_ w: Int, _ h: Int) -> MTLTexture {
    let t = texture("uint", w, h)
    var px = [UInt16](repeating: 0, count: w * h * 4)
    for i in 0..<(w * h) {
        px[4 * i + 1] = 8192
    }
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 8)
    return t
}

func readStdin(_ n: Int) -> [UInt8] {
    var buf = [UInt8]()
    buf.reserveCapacity(n)
    while buf.count < n {
        let chunk = FileHandle.standardInput.readData(ofLength: n - buf.count)
        if chunk.isEmpty { fatalError("stdin ended early") }
        buf.append(contentsOf: chunk)
    }
    return buf
}

final class Limiter {
    let w: Int, h: Int
    let frame: MTLTexture, rows: MTLTexture, s: MTLTexture, c: MTLTexture, win: MTLTexture
    let g: [MTLTexture], track: [MTLTexture], out: [MTLTexture]
    var cur = 0

    init(_ w: Int, _ h: Int) {
        self.w = w
        self.h = h
        frame = texture("float", w, h)
        rows = texture("uint32", 64, h)
        s = texture("uint32", 64, 36)
        c = texture("uint32", 16, 9)
        win = texture("uint", 16, 9)
        g = [texture("uint", 1, 1), texture("uint", 1, 1)]
        track = [trackTexture(w, h), trackTexture(w, h)]
        out = [texture("float", w, h), texture("float", w, h)]
    }

    func upload(_ px: [UInt8]) {
        frame.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
    }

    /// The passes of one frame in order, as (pass, targets, inputs).
    func passes() -> [(Int, [MTLTexture], [MTLTexture])] {
        let a = cur, b = cur ^ 1
        return [
            (0, [rows], [frame, track[a]]),
            (1, [s], [rows]),
            (2, [c], [s]),
            (3, [win], [c]),
            (4, [g[b]], [c, win, g[a]]),
            (5, [out[b], track[b]], [frame, out[a], track[a], g[b]]),
        ]
    }

    func encode(_ cb: MTLCommandBuffer, _ pass: (Int, [MTLTexture], [MTLTexture]), _ block: [Float]) {
        let rp = MTLRenderPassDescriptor()
        for (i, t) in pass.1.enumerated() {
            rp.colorAttachments[i].texture = t
            rp.colorAttachments[i].loadAction = .dontCare
            rp.colorAttachments[i].storeAction = .store
        }
        let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(pipelines[pass.0])
        var b = block
        enc.setFragmentBytes(&b, length: 32, index: 0)
        for (i, t) in pass.2.enumerated() { enc.setFragmentTexture(t, index: i) }
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

func blockOf(_ c: Case, _ t: Int) -> [Float] {
    [c.cols, c.rows, c.limit, c.clock[t][2], c.clock[t][0], c.clock[t][1], 0, 0]
}

func fnv1a(_ bytes: [UInt8]) -> String {
    var h: UInt32 = 0x811c9dc5
    for b in bytes { h = (h ^ UInt32(b)) &* 0x01000193 }
    return String(format: "%08x", h)
}

func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

for c in cfg.cases {
    let lim = Limiter(c.width, c.height)
    var frames: [[Any]] = []
    var sub = [UInt32](repeating: 0, count: 64 * 36 * 4)
    var track = [UInt16](repeating: 0, count: c.width * c.height * 4)
    var g = [UInt16](repeating: 0, count: 4)
    var out = [UInt8](repeating: 0, count: c.width * c.height * 4)
    for t in 0..<c.frames {
        lim.upload(readStdin(c.width * c.height * 4))
        let cb = queue.makeCommandBuffer()!
        let block = blockOf(c, t)
        for p in lim.passes() { lim.encode(cb, p, block) }
        lim.cur ^= 1
        let b = lim.cur
        cb.commit()
        cb.waitUntilCompleted()
        lim.s.getBytes(&sub, bytesPerRow: 64 * 16, from: MTLRegionMake2D(0, 0, 64, 36), mipmapLevel: 0)
        lim.track[b].getBytes(&track, bytesPerRow: c.width * 8, from: MTLRegionMake2D(0, 0, c.width, c.height), mipmapLevel: 0)
        lim.g[b].getBytes(&g, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        lim.out[b].getBytes(&out, bytesPerRow: c.width * 4, from: MTLRegionMake2D(0, 0, c.width, c.height), mipmapLevel: 0)
        // A sub-block holds where one of its pixels does: it requests a direction the grant did not admit.
        let grant = UInt32(g[0])
        let mask = String((0..<(64 * 36)).map { sub[4 * $0 + 1] & ~grant & 15 != 0 ? Character("1") : Character("0") })
        let trackBytes = track.withUnsafeBytes { [UInt8]($0) }
        // Every grant word, as grant.glsl writes it (Codex round 17).
        frames.append([mask, Int(g[0]), Int(g[1]), Int(g[2]), Int(g[3]), fnv1a(out), fnv1a(trackBytes)])
    }
    emit(["name": c.name, "frames": frames])
}

if let c = cfg.timing {
    let lim = Limiter(c.width, c.height)
    let pixels = [readStdin(c.width * c.height * 4), readStdin(c.width * c.height * 4)]
    var frameMs: [Double] = []
    var passMs = [[Double]](repeating: [], count: cfg.passes.count)
    for t in 0..<c.frames {
        lim.upload(pixels[t % 2])
        let block = blockOf(c, t)
        // All the passes in one command buffer: the frame's cost.
        let cb = queue.makeCommandBuffer()!
        for p in lim.passes() { lim.encode(cb, p, block) }
        cb.commit()
        cb.waitUntilCompleted()
        frameMs.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
        // Then each pass in a command buffer of its own over the same inputs: the breakdown.
        for p in lim.passes() {
            let one = queue.makeCommandBuffer()!
            lim.encode(one, p, block)
            one.commit()
            one.waitUntilCompleted()
            passMs[p.0].append((one.gpuEndTime - one.gpuStartTime) * 1000)
        }
        lim.cur ^= 1
    }
    func median(_ xs: [Double]) -> Double {
        let v = xs.dropFirst(30).sorted()
        return v.isEmpty ? 0 : v[v.count / 2]
    }
    emit(["timing": ["device": device.name, "frameMedianMs": median(frameMs), "passMedianMs": passMs.map(median), "frames": c.frames]])
}
