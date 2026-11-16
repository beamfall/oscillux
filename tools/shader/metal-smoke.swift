// SPDX-License-Identifier: AGPL-3.0-only
// Render one frame of a generated Metal fragment shader and print its luma
// stats as JSON. Driven by render.mjs; see that file for the config shape.
// `params` (3 values) and `trailDecay` are optional and default to the manifest
// defaults, 0.5/0.5/0.5 and 0.82.
import Foundation
import Metal

struct Config: Decodable {
    let metal: String
    let function: String
    let width: Int
    let height: Int
    let palette: [Float]
    let params: [Float]?
    let trailDecay: Float?
    let audio: Audio
}

struct Audio: Decodable {
    let amplitude: Float
    let bass: Float
    let mid: Float
    let treble: Float
    let beat: Float
    let beatPhase: Float
    let onset: Float
    let bassImpact: Float
    let level: Float
    let spectralCentroid: Float
    let flux: Float
    let beatCount: Float
    let spectrum: [Float]
}

let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
guard let device = MTLCreateSystemDefaultDevice() else {
    // Exit 0: render.mjs parses the skipped JSON from stdout and decides
    // (skip locally, fail on CI). A non-zero exit makes execFileSync throw
    // before the JSON is read, so every skip was miscounted as MSL-FAIL.
    print("{\"skipped\":\"no-metal-device\"}")
    exit(0)
}

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

let source = try String(contentsOfFile: cfg.metal, encoding: .utf8) + vertex
let library = try device.makeLibrary(source: source, options: nil)
let descriptor = MTLRenderPipelineDescriptor()
descriptor.vertexFunction = library.makeFunction(name: "oscillux_vertex")
descriptor.fragmentFunction = library.makeFunction(name: cfg.function)
descriptor.colorAttachments[0].pixelFormat = .rgba16Float
let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
let queue = device.makeCommandQueue()!

let targetDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: cfg.width, height: cfg.height, mipmapped: false)
targetDesc.usage = [.renderTarget, .shaderRead]
let target = device.makeTexture(descriptor: targetDesc)!
let image = makeTexture(device: device, w: 64, h: 64, gradient: true)
let prev = makeTexture(device: device, w: cfg.width, h: cfg.height, gradient: false)
let uniforms = device.makeBuffer(bytes: uniformsBytes(cfg), length: 448)!
let samplerDesc = MTLSamplerDescriptor()
samplerDesc.minFilter = .linear
samplerDesc.magFilter = .linear
samplerDesc.sAddressMode = .clampToEdge
samplerDesc.tAddressMode = .clampToEdge
let sampler = device.makeSamplerState(descriptor: samplerDesc)!

let pass = MTLRenderPassDescriptor()
pass.colorAttachments[0].texture = target
pass.colorAttachments[0].loadAction = .clear
pass.colorAttachments[0].storeAction = .store
pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
let command = queue.makeCommandBuffer()!
let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
encoder.setRenderPipelineState(pipeline)
encoder.setFragmentBuffer(uniforms, offset: 0, index: 0)
encoder.setFragmentTexture(image, index: 0)
encoder.setFragmentTexture(prev, index: 1)
encoder.setFragmentSamplerState(sampler, index: 0)
encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
encoder.endEncoding()
command.commit()
command.waitUntilCompleted()
if let error = command.error { throw error }

// Read the HDR frame back and apply the web reference's readback step (ACES,
// then gamma 1/2.2), so coverage and the pixel diff compare the same transfer.
var hdr = [Float16](repeating: 0, count: cfg.width * cfg.height * 4)
target.getBytes(&hdr, bytesPerRow: cfg.width * 8, from: MTLRegionMake2D(0, 0, cfg.width, cfg.height), mipmapLevel: 0)
func toneMap(_ v: Float16) -> UInt8 {
    let x = max(Float(v), 0)
    let y = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)
    return UInt8(clamping: Int((pow(min(max(y, 0), 1), 1 / 2.2) * 255).rounded()))
}
let pixels = hdr.map(toneMap)
var lit = 0
var luma = 0.0
var pixelLuma = [UInt8]()
pixelLuma.reserveCapacity(cfg.width * cfg.height)
for i in stride(from: 0, to: pixels.count, by: 4) {
    let y = 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
    luma += y
    pixelLuma.append(UInt8(clamping: Int(y.rounded())))
    if y > 10 { lit += 1 }
}
let grid = lumaGrid(pixels, cfg.width, cfg.height)
let json = "{\"coverage\":\(Double(lit) / Double(cfg.width * cfg.height)),\"meanLuma\":\(luma / Double(cfg.width * cfg.height) / 255.0),\"grid\":[\(grid.map { String(format: "%.6f", $0) }.joined(separator: ","))],\"pixelLuma\":[\(pixelLuma.map(String.init).joined(separator: ","))]}"
print(json)

func makeTexture(device: MTLDevice, w: Int, h: Int, gradient: Bool) -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.shaderRead]
    let tex = device.makeTexture(descriptor: desc)!
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            if gradient {
                px[i] = UInt8(clamping: Int(40 + Double(x) * 2.5))
                px[i + 1] = UInt8(clamping: Int(30 + Double(y) * 1.8))
                px[i + 2] = UInt8(clamping: Int(120 + ((x + y) & 15) * 6))
            }
            px[i + 3] = 255
        }
    }
    tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
    return tex
}

func uniformsBytes(_ cfg: Config) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 448)
    let audio = cfg.audio
    put2(&b, 0, Float(cfg.width), Float(cfg.height))
    put(&b, 12, 1.0 / 60.0)
    put(&b, 16, audio.amplitude)
    put(&b, 20, audio.bass)
    put(&b, 24, audio.mid)
    put(&b, 28, audio.treble)
    put(&b, 32, audio.beat)
    put(&b, 36, audio.beatPhase)
    put(&b, 40, audio.onset)
    put(&b, 44, 1.0)
    let params = cfg.params ?? [0.5, 0.5, 0.5]
    guard params.count == 3 else { fatalError("params must have 3 values") }
    put(&b, 48, params[0]); put(&b, 52, params[1]); put(&b, 56, params[2])
    put(&b, 60, audio.level)
    put(&b, 64, audio.bassImpact)
    put(&b, 68, audio.spectralCentroid)
    put(&b, 72, audio.flux)
    put(&b, 76, audio.beatCount)
    put(&b, 80, cfg.trailDecay ?? 0.82)
    put4(&b, 96, 0.15, 0.9, 0.72, 1)
    put4(&b, 128, cfg.palette[0], cfg.palette[1], cfg.palette[2], cfg.palette[3])
    put4(&b, 144, 0, 1, 0, 0)
    put4(&b, 160, 1, 0, 0, 0)
    put4(&b, 176, 0.05, 0.05, 0.05, 0.05)
    for i in 0..<min(64, audio.spectrum.count) { put(&b, 192 + i * 4, audio.spectrum[i]) }
    return b
}

func put(_ b: inout [UInt8], _ off: Int, _ value: Float) {
    var v = value
    withUnsafeBytes(of: &v) { bytes in
        for i in 0..<4 { b[off + i] = bytes[i] }
    }
}
func put2(_ b: inout [UInt8], _ off: Int, _ x: Float, _ y: Float) { put(&b, off, x); put(&b, off + 4, y) }
func put4(_ b: inout [UInt8], _ off: Int, _ x: Float, _ y: Float, _ z: Float, _ w: Float) {
    put(&b, off, x); put(&b, off + 4, y); put(&b, off + 8, z); put(&b, off + 12, w)
}

func lumaGrid(_ px: [UInt8], _ w: Int, _ h: Int) -> [Double] {
    let gw = 8, gh = 8
    var out = [Double](repeating: 0, count: gw * gh)
    for gy in 0..<gh {
        for gx in 0..<gw {
            var sum = 0.0, count = 0.0
            let x0 = gx * w / gw, x1 = (gx + 1) * w / gw
            let y0 = gy * h / gh, y1 = (gy + 1) * h / gh
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * w + x) * 4
                    sum += (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255.0
                    count += 1
                }
            }
            out[gy * gw + gx] = sum / count
        }
    }
    return out
}
