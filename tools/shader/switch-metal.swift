// SPDX-License-Identifier: AGPL-3.0-only
// Draws the switch-transition pass's Metal source (tools/shader/switch.mjs) for
// switch-transition-check.mjs. The device's runtime compiler builds the library, so this is also
// the Metal compile when the offline toolchain (xcrun metal) is absent. The config is
//   { metal, function, vectors?: { size, from, to, photo, blocks: [hex], out },
//     perf?: { width, height, blocks: [hex], draws, samples, warmup } }
// vectors: from/to/photo are raw little-endian float32 RGBA images, size x size, row 0 first;
// every 48-byte SwitchBlock is drawn into an rgba32Float target and the targets are written to
// out back to back as raw float32 RGBA, row 0 first.
// perf: every block is drawn full-frame into an rgba16Float target from three rgba16Float
// inputs through a linear clamp-to-edge sampler; each sample is one command buffer of `draws`
// render passes, timed by its GPU start and end times. Prints JSON with the device name and,
// for perf, the per-block milliseconds per draw (median, p95, min over samples). Prints
// {"skipped":...} without a Metal device.
import Foundation
import Metal

struct Vectors: Decodable {
    let size: Int
    let from: String
    let to: String
    let photo: String
    let blocks: [String]
    let out: String
}

struct Perf: Decodable {
    let width: Int
    let height: Int
    let blocks: [String]
    let draws: Int
    let samples: Int
    let warmup: Int
}

struct Config: Decodable {
    let metal: String
    let function: String
    let vectors: Vectors?
    let perf: Perf?
}

let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
guard let device = MTLCreateSystemDefaultDevice() else {
    print("{\"skipped\":\"no-metal-device\"}")
    exit(0)
}

let vertex = """

struct OscilluxSwitchVertexOut {
    float4 position [[position]];
};
vertex OscilluxSwitchVertexOut oscillux_switch_vertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    OscilluxSwitchVertexOut out;
    out.position = float4(p[vid], 0.0, 1.0);
    return out;
}
"""

let library = try device.makeLibrary(source: try String(contentsOfFile: cfg.metal, encoding: .utf8) + vertex, options: nil)
let queue = device.makeCommandQueue()!
let samplerDesc = MTLSamplerDescriptor()
samplerDesc.minFilter = .linear
samplerDesc.magFilter = .linear
samplerDesc.sAddressMode = .clampToEdge
samplerDesc.tAddressMode = .clampToEdge
let sampler = device.makeSamplerState(descriptor: samplerDesc)!

func pipeline(_ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "oscillux_switch_vertex")
    desc.fragmentFunction = library.makeFunction(name: cfg.function)
    desc.colorAttachments[0].pixelFormat = format
    return try device.makeRenderPipelineState(descriptor: desc)
}

func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
    d.usage = usage
    d.storageMode = .shared
    return device.makeTexture(descriptor: d)!
}

func bytes(hex: String) -> [UInt8] {
    var out = [UInt8]()
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        out.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return out
}

func encode(_ command: MTLCommandBuffer, _ state: MTLRenderPipelineState, _ target: MTLTexture,
            _ inputs: [MTLTexture], _ block: inout [UInt8]) {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .dontCare
    pass.colorAttachments[0].storeAction = .store
    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
    encoder.setRenderPipelineState(state)
    encoder.setFragmentBytes(&block, length: block.count, index: 0)
    for (i, t) in inputs.enumerated() { encoder.setFragmentTexture(t, index: i) }
    encoder.setFragmentSamplerState(sampler, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
}

var reply: [String: Any] = ["ok": true, "device": device.name]

if let v = cfg.vectors {
    let state = try pipeline(.rgba32Float)
    let n = v.size
    let inputs = try [v.from, v.to, v.photo].map { path -> MTLTexture in
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count == n * n * 16 else { fatalError("\(path): \(data.count) bytes") }
        let t = texture(.rgba32Float, n, n, [.shaderRead])
        data.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: n * 16) }
        return t
    }
    var out = Data()
    for hex in v.blocks {
        var block = bytes(hex: hex)
        guard block.count == 48 else { fatalError("block is \(block.count) bytes") }
        let target = texture(.rgba32Float, n, n, [.renderTarget, .shaderRead])
        let command = queue.makeCommandBuffer()!
        encode(command, state, target, inputs, &block)
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var px = [Float](repeating: 0, count: n * n * 4)
        target.getBytes(&px, bytesPerRow: n * 16, from: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0)
        px.withUnsafeBytes { out.append(contentsOf: $0) }
    }
    try out.write(to: URL(fileURLWithPath: v.out))
}

if let p = cfg.perf {
    let state = try pipeline(.rgba16Float)
    let (w, h) = (p.width, p.height)
    // Three distinct full-range HDR inputs, so every tap reads real data.
    let inputs = (0..<3).map { k -> MTLTexture in
        var px = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let u = Float(x) / Float(w), v = Float(y) / Float(h)
                px[i] = Float16(u * Float(k + 1))
                px[i + 1] = Float16(v * 2.0)
                px[i + 2] = Float16(Float((x / (8 + k) + y / 8) % 2))
                px[i + 3] = 1
            }
        }
        let t = texture(.rgba16Float, w, h, [.shaderRead])
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 8)
        return t
    }
    let target = texture(.rgba16Float, w, h, [.renderTarget])
    var results = [[String: Double]]()
    for hex in p.blocks {
        var block = bytes(hex: hex)
        var times = [Double]()
        for s in 0..<(p.warmup + p.samples) {
            let command = queue.makeCommandBuffer()!
            for _ in 0..<p.draws { encode(command, state, target, inputs, &block) }
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            if s >= p.warmup { times.append((command.gpuEndTime - command.gpuStartTime) * 1000.0 / Double(p.draws)) }
        }
        times.sort()
        results.append([
            "median": times[times.count / 2],
            "p95": times[min(times.count - 1, Int(Double(times.count) * 0.95))],
            "min": times[0],
        ])
    }
    reply["perf"] = results
}

let json = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
print(String(data: json, encoding: .utf8)!)
