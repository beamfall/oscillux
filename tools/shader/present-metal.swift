// SPDX-License-Identifier: AGPL-3.0-only
// Draws the shared present pass's Metal source over given inputs, as Renderer.swift draws it,
// for overlay-check.mjs's WebGL2 / Metal comparison. The config is
//   { metal, function, cases: [{ name, width, height, block (hex), frames: [path], out }] }
// with each frame a raw little-endian float32 RGBA scene (rows in vUV order, top row first) and
// block the 368-byte PresentBlock. Every case starts from an empty history and presents its
// frames in order into an rgba8Unorm colour target and an rgba16Float history pair; the last
// colour target is written to out as raw RGBA8, top row first. A case built with a host layer
// also gives layerBlocks (one 128-byte PresentLayerBlock per frame, buffer 1) and layerTexture
// (RGBA8, layerWidth x layerHeight, texture 3, nearest sampler 1). Prints {"ok":true}, or
// {"skipped":...} without a Metal device.
import Foundation
import Metal

struct Case: Decodable {
    let name: String
    let width: Int
    let height: Int
    let block: String
    let frames: [String]
    let out: String
    let layerBlocks: [String]?
    let layerTexture: String?
    let layerWidth: Int?
    let layerHeight: Int?
}

struct Config: Decodable {
    let metal: String
    let function: String
    let cases: [Case]
}

let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
guard let device = MTLCreateSystemDefaultDevice() else {
    print("{\"skipped\":\"no-metal-device\"}")
    exit(0)
}

// Renderer.swift's vertex stage.
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

let library = try device.makeLibrary(source: try String(contentsOfFile: cfg.metal, encoding: .utf8) + vertex, options: nil)
let desc = MTLRenderPipelineDescriptor()
desc.vertexFunction = library.makeFunction(name: "oscillux_vertex")
desc.fragmentFunction = library.makeFunction(name: cfg.function)
desc.colorAttachments[0].pixelFormat = .rgba8Unorm
desc.colorAttachments[1].pixelFormat = .rgba16Float
let pipeline = try device.makeRenderPipelineState(descriptor: desc)
let queue = device.makeCommandQueue()!
let samplerDesc = MTLSamplerDescriptor()
samplerDesc.minFilter = .linear
samplerDesc.magFilter = .linear
samplerDesc.sAddressMode = .clampToEdge
samplerDesc.tAddressMode = .clampToEdge
let sampler = device.makeSamplerState(descriptor: samplerDesc)!
let nearestDesc = MTLSamplerDescriptor()
nearestDesc.sAddressMode = .clampToEdge
nearestDesc.tAddressMode = .clampToEdge
let nearest = device.makeSamplerState(descriptor: nearestDesc)!

func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
    d.usage = usage
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

for c in cfg.cases {
    var block = bytes(hex: c.block)
    guard block.count == 368 else { fatalError("\(c.name): block is \(block.count) bytes") }
    let color = texture(.rgba8Unorm, c.width, c.height, [.renderTarget, .shaderRead])
    let history = (0..<2).map { _ in texture(.rgba16Float, c.width, c.height, [.renderTarget, .shaderRead]) }
    let zero = [Float16](repeating: 0, count: c.width * c.height * 4)
    for h in history {
        h.replace(region: MTLRegionMake2D(0, 0, c.width, c.height), mipmapLevel: 0, withBytes: zero, bytesPerRow: c.width * 8)
    }
    var layerTex: MTLTexture?
    if let hex = c.layerTexture, let lw = c.layerWidth, let lh = c.layerHeight {
        let t = texture(.rgba8Unorm, lw, lh, [.shaderRead])
        t.replace(region: MTLRegionMake2D(0, 0, lw, lh), mipmapLevel: 0, withBytes: bytes(hex: hex), bytesPerRow: lw * 4)
        layerTex = t
    }
    var cur = 0
    for (index, path) in c.frames.enumerated() {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count == c.width * c.height * 16 else { fatalError("\(path): \(data.count) bytes") }
        let halves: [Float16] = data.withUnsafeBytes { raw in raw.bindMemory(to: Float.self).map { Float16($0) } }
        let scene = texture(.rgba16Float, c.width, c.height, [.shaderRead])
        scene.replace(region: MTLRegionMake2D(0, 0, c.width, c.height), mipmapLevel: 0, withBytes: halves, bytesPerRow: c.width * 8)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = history[cur ^ 1]
        pass.colorAttachments[1].loadAction = .dontCare
        pass.colorAttachments[1].storeAction = .store
        let command = queue.makeCommandBuffer()!
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&block, length: block.count, index: 0)
        encoder.setFragmentTexture(scene, index: 0)
        encoder.setFragmentTexture(scene, index: 1)
        encoder.setFragmentTexture(history[cur], index: 2)
        encoder.setFragmentTexture(scene, index: 4) // the bloom level: bound, unread with post0.x 0
        encoder.setFragmentSamplerState(sampler, index: 0)
        if let blocks = c.layerBlocks, let layerTex {
            var layer = bytes(hex: blocks[index])
            encoder.setFragmentBytes(&layer, length: layer.count, index: 1)
            encoder.setFragmentTexture(layerTex, index: 3)
            encoder.setFragmentSamplerState(nearest, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        cur ^= 1
    }
    var out = [UInt8](repeating: 0, count: c.width * c.height * 4)
    color.getBytes(&out, bytesPerRow: c.width * 4, from: MTLRegionMake2D(0, 0, c.width, c.height), mipmapLevel: 0)
    try Data(out).write(to: URL(fileURLWithPath: c.out))
}
print("{\"ok\":true}")
