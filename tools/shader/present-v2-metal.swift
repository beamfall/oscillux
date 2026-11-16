// SPDX-License-Identifier: AGPL-3.0-only
// Runs pass lists through Metal for present-v2-check.mjs (CORE-0108): the present pass and the
// bloom chain over given inputs, as a host draws them, read back and timed. The config is
//   { programs: [{ name, metal, function, formats: [pixel format], blend: "replace"|"add" }],
//     textures: [{ name, width, height, format, data? }],
//     runs: [{ name, warmup, iterations, passes: [pass], read: [{ texture, out }] }] }
// with pass = { program, targets: [texture], load: bool, textures: { index: texture },
// bytes: { index: hex } }. Formats are rgba8Unorm, rgba16Float or rgba32Float; a texture's data
// is a raw little-endian float32 RGBA file, top row first, converted to the texture's format;
// without data a texture starts at zero. Every texture uses the linear clamp sampler at index 0.
// Each iteration encodes the run's passes into one command buffer; the result gives the GPU time
// of each iteration's command buffer (gpuEndTime - gpuStartTime, warm-up iterations dropped) and
// writes each read texture's raw bytes, top row first. Prints the result as JSON, or
// {"skipped":...} without a Metal device.
import Foundation
import Metal

struct Program: Decodable {
    let name: String
    let metal: String
    let function: String
    let formats: [String]
    let blend: String
}

struct TextureSpec: Decodable {
    let name: String
    let width: Int
    let height: Int
    let format: String
    let data: String?
}

struct Pass: Decodable {
    let program: String
    let targets: [String]
    let load: Bool?
    let textures: [String: String]
    let bytes: [String: String]
}

struct Read: Decodable {
    let texture: String
    let out: String
}

struct Run: Decodable {
    let name: String
    let warmup: Int
    let iterations: Int
    let passes: [Pass]
    let read: [Read]
}

struct Config: Decodable {
    let programs: [Program]
    let textures: [TextureSpec]
    let runs: [Run]
}

let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
guard let device = MTLCreateSystemDefaultDevice() else {
    print("{\"skipped\":\"no-metal-device\"}")
    exit(0)
}

// Renderer.swift's vertex stage: vUV is the viewport position, origin top-left.
let vertex = """

struct OscilluxVertexOut {
    float4 position [[position]];
    float2 vUV [[user(locn0)]];
};
vertex OscilluxVertexOut oscillux_vertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    OscilluxVertexOut out;
    out.position = float4(p[vid], 0.0, 1.0);
    out.vUV = float2(p[vid].x * 0.5 + 0.5, 0.5 - p[vid].y * 0.5);
    return out;
}
"""

func format(_ name: String) -> MTLPixelFormat {
    switch name {
    case "rgba8Unorm": return .rgba8Unorm
    case "rgba16Float": return .rgba16Float
    case "rgba32Float": return .rgba32Float
    default: fatalError("unknown pixel format \(name)")
    }
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

var pipelines = [String: MTLRenderPipelineState]()
for p in cfg.programs {
    let library = try device.makeLibrary(source: try String(contentsOfFile: p.metal, encoding: .utf8) + vertex, options: nil)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "oscillux_vertex")
    guard let fragment = library.makeFunction(name: p.function) else { fatalError("\(p.name): no \(p.function)") }
    desc.fragmentFunction = fragment
    for (i, f) in p.formats.enumerated() {
        desc.colorAttachments[i].pixelFormat = format(f)
        if p.blend == "add" {
            desc.colorAttachments[i].isBlendingEnabled = true
            desc.colorAttachments[i].rgbBlendOperation = .add
            desc.colorAttachments[i].alphaBlendOperation = .add
            desc.colorAttachments[i].sourceRGBBlendFactor = .one
            desc.colorAttachments[i].destinationRGBBlendFactor = .one
            desc.colorAttachments[i].sourceAlphaBlendFactor = .zero
            desc.colorAttachments[i].destinationAlphaBlendFactor = .one
        }
    }
    pipelines[p.name] = try device.makeRenderPipelineState(descriptor: desc)
}

var textures = [String: MTLTexture]()
for t in cfg.textures {
    let f = format(t.format)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: t.width, height: t.height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    let tex = device.makeTexture(descriptor: d)!
    let n = t.width * t.height * 4
    let floats: [Float] = try t.data.map { path in
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count == n * 4 else { fatalError("\(path): \(data.count) bytes") }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    } ?? [Float](repeating: 0, count: n)
    let region = MTLRegionMake2D(0, 0, t.width, t.height)
    switch f {
    case .rgba8Unorm:
        let b = floats.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        tex.replace(region: region, mipmapLevel: 0, withBytes: b, bytesPerRow: t.width * 4)
    case .rgba16Float:
        let h = floats.map { Float16($0) }
        tex.replace(region: region, mipmapLevel: 0, withBytes: h, bytesPerRow: t.width * 8)
    default:
        tex.replace(region: region, mipmapLevel: 0, withBytes: floats, bytesPerRow: t.width * 16)
    }
    textures[t.name] = tex
}

let samplerDesc = MTLSamplerDescriptor()
samplerDesc.minFilter = .linear
samplerDesc.magFilter = .linear
samplerDesc.sAddressMode = .clampToEdge
samplerDesc.tAddressMode = .clampToEdge
let sampler = device.makeSamplerState(descriptor: samplerDesc)!
let queue = device.makeCommandQueue()!

func tex(_ name: String) -> MTLTexture {
    guard let t = textures[name] else { fatalError("unknown texture \(name)") }
    return t
}

var report = [String: Any]()
report["device"] = device.name
var runs = [[String: Any]]()
for run in cfg.runs {
    var times = [Double]()
    for iteration in 0..<(run.warmup + run.iterations) {
        let command = queue.makeCommandBuffer()!
        for pass in run.passes {
            let desc = MTLRenderPassDescriptor()
            for (i, name) in pass.targets.enumerated() {
                desc.colorAttachments[i].texture = tex(name)
                desc.colorAttachments[i].loadAction = pass.load == true ? .load : .dontCare
                desc.colorAttachments[i].storeAction = .store
            }
            let enc = command.makeRenderCommandEncoder(descriptor: desc)!
            guard let pipeline = pipelines[pass.program] else { fatalError("unknown program \(pass.program)") }
            enc.setRenderPipelineState(pipeline)
            for (index, hex) in pass.bytes {
                let b = bytes(hex: hex)
                b.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: b.count, index: Int(index)!) }
            }
            for (index, name) in pass.textures { enc.setFragmentTexture(tex(name), index: Int(index)!) }
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { fatalError("\(run.name): \(error)") }
        if iteration >= run.warmup { times.append((command.gpuEndTime - command.gpuStartTime) * 1000) }
    }
    for r in run.read {
        let t = tex(r.texture)
        let bpp = t.pixelFormat == .rgba8Unorm ? 4 : t.pixelFormat == .rgba16Float ? 8 : 16
        var out = [UInt8](repeating: 0, count: t.width * t.height * bpp)
        t.getBytes(&out, bytesPerRow: t.width * bpp, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        try Data(out).write(to: URL(fileURLWithPath: r.out))
    }
    runs.append(["name": run.name, "gpuMs": times])
}
report["runs"] = runs
print(String(data: try JSONSerialization.data(withJSONObject: report), encoding: .utf8)!)
