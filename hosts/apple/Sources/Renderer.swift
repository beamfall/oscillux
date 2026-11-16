// SPDX-License-Identifier: AGPL-3.0-only
// Metal renderer for a bundled visual set (tools/shader/bundle-hosts.mjs). The
// pipeline matches hosts/web/host.js and tools/shader/render.mjs: RGBA16F
// ping-pong feedback, synthetic audio, a fixed 1/60 s step and the bundle's
// shared present pass (shaders/present/present.glsl) with the overlay regions
// of Overlay.swift. Visual sources are the bundle's SPIRV-Cross MSL, compiled at runtime
// the way tools/shader/metal-smoke.swift compiles them.
import MetalKit

struct VisualBundle: Decodable {
    struct Visual: Decodable {
        let id: String
        let title: String
        let imageInput: Bool
        let palette: [Float]
        let params: [Float]
        let trailDecay: Float
        let metal: String
        let metalFunction: String
        /// Its category ids, from hosts/categories.json.
        let type: String
        let intensity: String
    }
    /// A visual type or intensity the picker filters by.
    struct Category: Decodable {
        let id: String
        let label: String
    }
    /// A switch effect: blends the outgoing frame (texture 0) into the incoming
    /// one (texture 1), with the progress and a seed in presentation0.
    struct Transition: Decodable {
        let id: String
        let title: String
        let metal: String
        let metalFunction: String
    }
    /// The shared present pass (tools/shader/present.mjs).
    struct Present: Decodable {
        let web: String
        let metal: String
        let metalFunction: String
    }
    let visuals: [Visual]
    let types: [Category]
    let intensities: [Category]
    let transitions: [Transition]
    let present: Present
    /// The present pass with the CD+G lyric layer (tools/shader/cdg-layer.mjs), used on screen
    /// while lyrics are loaded.
    let presentCdg: Present?

    static func load() throws -> VisualBundle {
        guard let url = Bundle.main.url(forResource: "visuals", withExtension: "json") else {
            throw HostError("visuals.json is missing from the app bundle; run make host-bundle")
        }
        return try JSONDecoder().decode(VisualBundle.self, from: Data(contentsOf: url))
    }
}

struct HostError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private let vertexSource = """

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

// The present pass is the bundle's shared one, as on the web. Its block is
// present0 (saturation, eased switch progress or 1 outside a switch, tone 1 or 0
// for the unmapped blend, vibrance), the 320-byte OverlayUniforms, then post0
// (bloom, aberration, grain, dither in codes) and post1 (the dither's frame seed);
// this host keeps bloom, aberration and grain at 0 and dithers by one code.
// Textures 0, 1 and 2 are the incoming frame, the outgoing frame and the
// history: the previous presented frame, display-linear, that it damps against.
// Texture 4 is the bloom level, read only when post0.x > 0. Colour 1 writes the
// next history.
private let presentHead = 16
private let overlaySize = 320
private let presentPost = presentHead + overlaySize
private let presentBlockSize = presentPost + 32

/// One running visual: its pipeline, feedback targets and clock. A layer steps
/// every stride frames and advances its clock by stride each time; an outgoing
/// layer with stride 0 holds its last frame.
private final class Layer {
    let visual: VisualBundle.Visual
    let pipeline: MTLRenderPipelineState
    var targets: [MTLTexture] = []
    var needsClear = true
    var frame = 0
    var stride = 1
    init(_ visual: VisualBundle.Visual, _ pipeline: MTLRenderPipelineState) {
        self.visual = visual
        self.pipeline = pipeline
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    static let dt = 1.0 / 60.0
    /// A switch is scheduled by TransitionDirector in presentation time: the
    /// incoming visual starts at the request and runs offscreen through the
    /// pre-roll, the blend starts on the next bar (or beat) and lasts four
    /// beats, 0.8 to 2.5 s, or 1.6 s without a beat. The outgoing visual keeps
    /// running during it, every frame when the averaged GPU time leaves room
    /// for two visuals. Otherwise it steps every second or third frame at the
    /// same speed, so the average frame stays within 90% of the budget. Above
    /// that its frame holds and only drifts. hosts/web/host.js has the same
    /// transition.
    static func outgoingStride(_ ms: Double?) -> Int {
        guard let ms else { return 2 }
        let n = Int((ms / max(0.9 * 1000 / 60 - ms, 1e-3)).rounded(.up))
        return n <= 3 ? max(n, 1) : 0
    }
    /// Quality levels, lowest first: render scale of each side, and the detail
    /// reduction passed in presentation1.y. hosts/web/host.js has the same ladder.
    static let ladder: [(scale: Double, reduce: Float)] = [(0.5, 1), (0.67, 0.6), (0.83, 0.25), (1, 0)]
    /// Pipeline keys for transitions; visual ids cannot contain a slash.
    static func transitionKey(_ id: String) -> String { "transition/" + id }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let present: MTLRenderPipelineState
    /// The present pass into an RGBA16F target, to bake a blend in progress.
    private let presentHDR: MTLRenderPipelineState
    /// The present block, and the history targets at the drawable size: the
    /// one read and the one written this frame.
    private var presentBlock = [UInt8](repeating: 0, count: presentBlockSize)
    private var presentFrame: UInt32 = 0
    private var history: [MTLTexture] = []
    private var lastPresent: CFTimeInterval?
    private var overlayRegions = [OscilluxOverlayRegion](repeating: OscilluxOverlayRegion(), count: OverlayState.maxRegions)
    private let sampler: MTLSamplerState
    private let image: MTLTexture
    private let model: HostModel
    /// Visual pipelines by id, and transition pipelines by transitionKey(id).
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    /// Pipelines being compiled, and the compile errors of those that failed.
    private var building: Set<String> = []
    private var failures: [String: String] = [:]
    private var selected: String?
    /// The selected visual while its pipeline compiles.
    private var pending: VisualBundle.Visual?
    private var cur: Layer?
    /// The outgoing layer during a switch, and the steps the switch has run.
    private var out: Layer?
    private var progress = 0
    /// The switch's schedule and its blend progress p (0 until the incoming
    /// visual shows, exactly 1 on the last blended frame); `shown` once it has
    /// shown. `clock` is presentation time, which stops while paused. A switch
    /// is timed as a whole frame, both visuals and the blend (timedBoth), and
    /// the governor's level applies to the render size and detail (`level`)
    /// only between switches: a size change would end the switch.
    /// quantise=bar|beat|none as in hosts/web/host.js.
    private var director = TransitionDirector(quantise: ["none": TransitionScheduler.quantiseNone,
        "beat": TransitionScheduler.quantiseBeat][UserDefaults.standard.string(forKey: "quantise") ?? ""]
        ?? TransitionScheduler.quantiseBar)
    private var blendP = 0.0
    private var shown = false
    private var clock = 0.0
    private var timedBoth = false
    private var level: Int
    /// The switch's transition (nil for the present pass's own dissolve), its
    /// seed, and the target it blends into, which the present pass then maps.
    private var active: MTLRenderPipelineState?
    private var seed: Float = 0
    private var mix: MTLTexture?
    /// Switches so far, which picks the next transition from `order`: every
    /// transition once, in a fixed shuffle that hosts/web/host.js shares.
    private var switches = 0
    /// The transition picker's value when the next transition was last compiled.
    private var picked = ""
    private let order: [String]
    private var restartToken = 0
    private var uniforms = [UInt8](repeating: 0, count: 448)
    private var governor: Governor
    private var lastDraw: CFTimeInterval?
    private var frameMs: Double?
    private var gpuMs: Double?
    /// The last command buffer that drew the visual, read back for its GPU time.
    private var lastRender: MTLCommandBuffer?
    /// The display link's target presentation time of the frame being drawn (host seconds).
    var photonTime: CFTimeInterval?
    /// The synthetic source when no file plays, and the audio values of the latest stepped frame.
    private var synthetic: SyntheticSource?
    private var audio = ReactionAudio()
    /// With `-beat-trace <path>` and `-frames n`: the synthetic source's beat clock per stepped
    /// frame (step, beat position, pulse, locked, tempo), as the web host traces it, in rows
    /// reserved up front and written once when the run stops, so the frame path neither
    /// allocates nor writes.
    private var beatTracePath: String?
    private var beatTrace: [(steps: Int, position: Double, beat: Double, locked: Bool, tempo: Double)] = []
    /// With `-capture`: the present pass draws into this texture, of the drawable's size and
    /// format, instead of the drawable, so frames run without a display, and the frame after
    /// the last step is read back once for HostModel.capture.
    private var captureTarget: MTLTexture?
    private var captured = false
    /// The lyric present pass and its layer: texture 3 with a nearest sampler at index 1, and
    /// the 128-byte block at buffer 1 (output size, then cdg-layer.glsl's place and halo).
    private var presentCdg: MTLRenderPipelineState?
    private var lyrics: CdgLayer?
    private var layerSampler: MTLSamplerState?
    private var layerBlock: [Float] = [0, 0, 0, 0, 0, 1.5, 1, 0, 4.5, 3, 1, 0] + [Float](repeating: 0, count: 20)

    init(device: MTLDevice, view: MTKView, model: HostModel) throws {
        self.device = device
        self.model = model
        // The governor reads GPU time, not the frame interval: at vsync the
        // interval sticks at the refresh period and hides both a small overrun
        // (an occasional missed frame) and the headroom to step up. It steps
        // down above 90% of the 60 Hz budget and up below 25%: the next level,
        // with more pixels and more shader detail, can cost up to about 3.7×.
        governor = Governor(maxLevel: Renderer.ladder.count - 1, level: model.pinnedQuality ?? Renderer.ladder.count - 1,
                            demoteFactor: 0.9, promoteRefreshFactor: 0.01, promoteTargetFactor: 0.2)
        level = governor.level
        queue = device.makeCommandQueue()!
        guard let bundle = model.bundle else { throw HostError(model.error ?? "no visual bundle") }
        let library = try device.makeLibrary(source: bundle.present.metal + vertexSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "oscillux_vertex")
        guard let fragment = library.makeFunction(name: bundle.present.metalFunction) else {
            throw HostError("no Metal function \(bundle.present.metalFunction)")
        }
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        desc.colorAttachments[1].pixelFormat = .rgba16Float
        present = try device.makeRenderPipelineState(descriptor: desc)
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        desc.colorAttachments[1].pixelFormat = .invalid
        presentHDR = try device.makeRenderPipelineState(descriptor: desc)
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: s)!
        image = Renderer.standInImage(device)
        order = Renderer.shuffled((model.bundle?.transitions ?? []).map(\.id))
        // a lyric pass that does not build leaves the lyrics hidden, not the host down
        if let lyric = bundle.presentCdg {
            do {
                let library = try device.makeLibrary(source: lyric.metal + vertexSource, options: nil)
                guard let fragment = library.makeFunction(name: lyric.metalFunction) else {
                    throw HostError("no Metal function \(lyric.metalFunction)")
                }
                desc.fragmentFunction = fragment
                desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
                desc.colorAttachments[1].pixelFormat = .rgba16Float
                presentCdg = try device.makeRenderPipelineState(descriptor: desc)
                let n = MTLSamplerDescriptor()
                n.sAddressMode = .clampToEdge
                n.tAddressMode = .clampToEdge
                layerSampler = device.makeSamplerState(descriptor: n)
                lyrics = CdgLayer(device)
            } catch {
                NSLog("cdg: the lyric pass did not build, lyrics stay hidden (\(error))")
            }
        }
        if let path = UserDefaults.standard.string(forKey: "beat-trace"), model.stopAt != .max {
            beatTracePath = path
            beatTrace.reserveCapacity(model.stopAt)
        }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        cur?.targets = []
        history = []
        endSwitch()
    }

    func draw(in view: MTKView) {
        guard let command = queue.makeCommandBuffer() else { return }
        syncSelection(command)
        if picked != model.transition { prepareNextTransition() }
        startPending(command)
        let now = CACurrentMediaTime()
        if let lastDraw {
            let ms = (now - lastDraw) * 1000
            if ms < 250 { frameMs = frameMs.map { $0 + 0.1 * (ms - $0) } ?? ms }
            // presentation time stops while paused, and skips a long gap
            if !model.paused, let cur, cur.frame < model.stopAt { clock += min(now - lastDraw, 0.1) }
        }
        lastDraw = now
        if let done = lastRender, done.status == .completed || done.status == .error {
            if done.status == .completed {
                let ms = (done.gpuEndTime - done.gpuStartTime) * 1000
                if !timedBoth { gpuMs = gpuMs.map { $0 + 0.1 * (ms - $0) } ?? ms }
                if model.pinnedQuality == nil { governor.record(ms) }
            }
            lastRender = nil
            timedBoth = false
        }
        if out == nil { level = governor.level }
        let scale = Renderer.ladder[level].scale
        let w = max(1, Int((view.drawableSize.width * scale).rounded()))
        let h = max(1, Int((view.drawableSize.height * scale).rounded()))
        guard view.drawableSize.width > 0, view.drawableSize.height > 0, let cur else { return }
        // a size change ends a switch: both layers would lose their history anyway
        if let o = out, o.targets.isEmpty || o.targets[0].width != w || o.targets[0].height != h { endSwitch() }
        for layer in [cur, out].compactMap({ $0 }) {
            if layer.targets.isEmpty || layer.targets[0].width != w || layer.targets[0].height != h {
                layer.targets = (0..<2).map { _ in makeTarget(w, h) }
                layer.needsClear = true
            }
            guard layer.needsClear else { continue }
            for t in layer.targets {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = t
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                command.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
            layer.needsClear = false
        }
        let run = !model.paused && cur.frame < model.stopAt
        if run {
            sampleAudio(now)
            step(cur, command, w, h)
            if let out, out.stride > 0, progress % out.stride == 0 { step(out, command, w, h) }
            if out != nil { progress += 1 }
            // during a switch the whole frame is timed: both visuals and the blend
            if lastRender == nil { lastRender = command; timedBoth = out != nil }
        }
        // the lyrics at the stepped frame's media time; paused, the held time applies nothing,
        // and lyrics loaded meanwhile show at it
        if let stream = model.lyrics, let lyrics {
            lyrics.update(stream, key: model.cdgKey, ms: model.mic != nil ? nil : model.audio?.lastMediaMs ?? synthetic?.mediaMs, command)
        }
        if !run, cur.frame >= model.stopAt, let path = beatTracePath {
            beatTracePath = nil
            writeBeatTrace(path)
        }
        if out != nil {
            blendP = director.frame(clock)
            // pre-roll: until it shows, the incoming visual keeps up with
            // presentation time from the request, feedback included, so it has
            // run for the pre-roll at least when it first shows
            var n = 0
            while run && !shown && n < 4 && Double(cur.frame) * Renderer.dt < clock - director.status.requestSeconds {
                step(cur, command, w, h)
                n += 1
            }
        }
        if let active, out != nil, blendP > 0 {
            if mix?.width != w || mix?.height != h { mix = makeTarget(w, h) }
            blend(command, active, into: mix!)
        }
        if let target = presentTarget(view), let texture = target.pass.colorAttachments[0].texture {
            let pass = target.pass
            let dw = texture.width, dh = texture.height
            if history.first?.width != dw || history.first?.height != dh {
                // a new history starts empty (alpha 0): nothing is damped against another size
                history = (0..<2).map { _ in makeTarget(dw, dh) }
                for t in history {
                    let clear = MTLRenderPassDescriptor()
                    clear.colorAttachments[0].texture = t
                    clear.colorAttachments[0].loadAction = .clear
                    clear.colorAttachments[0].storeAction = .store
                    clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                    command.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
                }
            }
            packOverlay(dw, dh, now)
            pass.colorAttachments[1].texture = history[1]
            pass.colorAttachments[1].loadAction = .dontCare
            pass.colorAttachments[1].storeAction = .store
            composite(command.makeRenderCommandEncoder(descriptor: pass)!, tone: true)
            history.swapAt(0, 1)
            if let drawable = target.drawable { command.present(drawable) }
            #if os(macOS)
            if !run, cur.frame >= model.stopAt, model.capturePath != nil, !captured {
                captured = true
                readBack(command, texture, view)
            }
            #endif
        }
        command.commit()
        if out != nil {
            if blendP > 0 { shown = true }
            // the last blended frame, at p = 1, has been drawn
            if director.status.state == TransitionScheduler.stateDone { endSwitch() }
        }
        let frame = cur.frame
        guard frame % 10 == 0 || frame == model.stopAt else { return }
        let ms = frameMs.map { String(format: "%.1f", $0) } ?? "–"
        let gpu = gpuMs.map { String(format: "%.1f", $0) } ?? "–"
        var status = String(format: "frame %d · t %.2f s · %d×%d · quality %d%@ · %@ ms (GPU %@)", frame,
                            Double(frame) * Renderer.dt, w, h, governor.level,
                            model.pinnedQuality == nil ? "" : " (fixed)", ms, gpu)
        let source = model.audio.map { String(format: "%@ · %.1f s", $0.name, $0.now) } ?? model.mic?.name ?? "synthetic"
        status += audio.locked
            ? String(format: "\n%@ · %.1f BPM · beat %d · confidence %.2f", source, audio.tempo, audio.beatInBar + 1, audio.confidence)
            : String(format: "\n%@ · no tempo lock yet", source)
        if model.status.text != status { model.status.text = status }
    }

    private func syncSelection(_ command: MTLCommandBuffer) {
        guard selected != model.selection || restartToken != model.restartToken else { return }
        if restartToken != model.restartToken {
            synthetic?.restart()
            beatTrace.removeAll(keepingCapacity: true)
        }
        restartToken = model.restartToken
        if selected == model.selection {
            if let cur { begin(Layer(cur.visual, cur.pipeline), command) }
            return
        }
        selected = model.selection
        guard let next = model.bundle?.visuals.first(where: { $0.id == model.selection }) else { return }
        pending = next
        prepare(next.id, next.metal, next.metalFunction)
    }

    /// Starts the pending visual once its pipeline is ready, then compiles its
    /// neighbours so the previous and next buttons find them ready.
    private func startPending(_ command: MTLCommandBuffer) {
        guard let next = pending else { return }
        if let error = failures[next.id] {
            model.error = "\(next.id): \(error)"
            pending = nil
            return
        }
        guard let state = pipelines[next.id] else { return }
        pending = nil
        model.error = nil
        begin(Layer(next, state), command)
        let all = model.listed
        if let i = all.firstIndex(where: { $0.id == next.id }) {
            for v in [all[(i + 1) % all.count], all[(i + all.count - 1) % all.count]] {
                prepare(v.id, v.metal, v.metalFunction)
            }
        }
    }

    /// The transition the next switch uses: the one picked in the model, or
    /// the next in the shuffled cycle.
    private func nextTransition() -> VisualBundle.Transition? {
        let all = model.bundle?.transitions ?? []
        if let t = all.first(where: { $0.id == model.transition }) { return t }
        guard !order.isEmpty else { return nil }
        let id = order[switches % order.count]
        return all.first { $0.id == id }
    }

    /// A Fisher-Yates shuffle with a fixed 32-bit LCG, so both hosts cycle
    /// through the transitions in the same order.
    static func shuffled(_ ids: [String]) -> [String] {
        var a = ids, s: UInt32 = 1
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            s = s &* 1664525 &+ 1013904223
            a.swapAt(i, Int(s % UInt32(i + 1)))
        }
        return a
    }

    /// Compiles a pipeline off the main thread. Compiling on the frame that
    /// switches stalls it, so a switch waits for a visual's pipeline with the
    /// current visual still running, and uses a transition only once it is
    /// ready.
    private func prepare(_ key: String, _ source: String, _ function: String) {
        guard pipelines[key] == nil, failures[key] == nil, building.insert(key).inserted else { return }
        let device = self.device
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Renderer.makePipeline(device, source, function) }
            DispatchQueue.main.async {
                self.building.remove(key)
                switch result {
                case .success(let state): self.pipelines[key] = state
                case .failure(let error): self.failures[key] = error.localizedDescription
                }
            }
        }
    }

    /// Starts a layer from frame 0. After the first visual this is a switch: the
    /// current layer becomes the outgoing one. A switch during another first
    /// bakes the blend on screen into the outgoing layer, which then holds, so
    /// nothing on screen jumps.
    private func begin(_ layer: Layer, _ command: MTLCommandBuffer) {
        // A current layer with no targets has not drawn yet: it is dropped and
        // the outgoing layer stays as it is, but the switch still counts, as on the web.
        if let out, let cur {
            if !shown {
                // the incoming visual has not shown yet: it is dropped and the
                // outgoing one keeps running
            } else if !cur.targets.isEmpty, !out.targets.isEmpty {
                if let active {
                    blend(command, active, into: out.targets[1])
                } else {
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = out.targets[1]
                    pass.colorAttachments[0].loadAction = .dontCare
                    pass.colorAttachments[0].storeAction = .store
                    composite(command.makeRenderCommandEncoder(descriptor: pass)!, tone: false)
                }
                out.targets.swapAt(0, 1)
                out.stride = 0
            }
        } else if let cur, !cur.targets.isEmpty {
            out = cur
            cur.stride = Renderer.outgoingStride(gpuMs)
        }
        if out != nil {
            active = nextTransition().flatMap { pipelines[Renderer.transitionKey($0.id)] }
            seed = Float((Double(switches) * 0.618034).truncatingRemainder(dividingBy: 1))
            switches += 1
            requestSwitch()
        }
        prepareNextTransition()
        start(layer)
    }

    /// Compiles the transition the next switch will use, as the web page does
    /// after each switch and when the transition picker changes.
    private func prepareNextTransition() {
        picked = model.transition
        if let t = nextTransition() { prepare(Renderer.transitionKey(t.id), t.metal, t.metalFunction) }
    }

    /// Schedules the switch from the beat clock the visuals react to, in
    /// presentation time.
    private func requestSwitch() {
        var phase = 0.0, bar = 0.0, bpm = 0.0, confidence = 0.0
        guard out != nil else { return }
        // the reaction sampler's beat for the frame just stepped. The synthetic
        // source runs on the step clock, so below 60 Hz its music runs slower
        // by the step rate; a track or the microphone runs in real time. Before the tracker
        // locks there is no confident beat: the blend starts after the pre-roll.
        let rate = model.audio != nil || model.mic != nil ? 1 : min(1, frameMs.map { 1000 * Renderer.dt / $0 } ?? 1)
        if audio.locked {
            phase = audio.beatPhase
            bar = audio.barPhase
            bpm = audio.tempo * rate
            confidence = audio.confidence
        }
        director.clock = .init(timeSeconds: clock, beatPhase: phase, barPhase: bar, tempoBpm: bpm,
                               // quantise none ignores the beat: the blend starts after the pre-roll and lasts 1.6 s
                               confidence: director.quantise == TransitionScheduler.quantiseNone ? 0 : confidence)
        director.request()
        blendP = 0
        shown = false
    }

    private func endSwitch() {
        out = nil
        active = nil
        mix = nil
        director.reset()
        blendP = 0
    }

    /// Encodes the switch's transition from the outgoing frame to the incoming
    /// one into an RGBA16F target, with the incoming visual's uniforms and
    /// presentation0 = (progress, seed, 0, 0).
    private func blend(_ command: MTLCommandBuffer, _ pipeline: MTLRenderPipelineState, into target: MTLTexture) {
        guard let cur, let out else { return }
        let source = out.targets[0]
        pack(cur, target.width, target.height)
        put4(144, Float(blendP), seed, 0, 0)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let enc = command.makeRenderCommandEncoder(descriptor: pass)!
        enc.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentTexture(cur.targets[0], index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func start(_ layer: Layer) {
        cur = layer
        progress = 0
        governor.reset(governor.level)
        lastRender = nil  // it timed the previous visual
    }

    private func step(_ layer: Layer, _ command: MTLCommandBuffer, _ w: Int, _ h: Int) {
        pack(layer, w, h)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = layer.targets[1]
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let enc = command.makeRenderCommandEncoder(descriptor: pass)!
        enc.setRenderPipelineState(layer.pipeline)
        uniforms.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.setFragmentTexture(image, index: 0)
        enc.setFragmentTexture(layer.targets[0], index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        layer.targets.swapAt(0, 1)
        layer.frame += layer.stride
    }

    /// The present pass's target: the view's drawable, or on macOS under -capture the capture texture.
    private func presentTarget(_ view: MTKView) -> (pass: MTLRenderPassDescriptor, drawable: MTLDrawable?)? {
        #if os(macOS)
        if model.capturePath != nil {
            let w = Int(view.drawableSize.width), h = Int(view.drawableSize.height)
            if captureTarget?.width != w || captureTarget?.height != h {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: view.colorPixelFormat, width: w, height: h, mipmapped: false)
                desc.usage = [.renderTarget]
                desc.storageMode = .private
                captureTarget = device.makeTexture(descriptor: desc)
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = captureTarget
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = view.clearColor
            return (pass, nil)
        }
        #endif
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return nil }
        return (pass, drawable)
    }

    #if os(macOS)
    /// Copies the capture texture to shared memory in the frame's command buffer, and hands it
    /// to HostModel.capture on the main thread once the frame completes.
    private func readBack(_ command: MTLCommandBuffer, _ texture: MTLTexture, _ view: MTKView) {
        let w = texture.width, h = texture.height, row = w * 4
        guard let buffer = device.makeBuffer(length: row * h, options: .storageModeShared),
              let blit = command.makeBlitCommandEncoder() else { return NSLog("capture: no read-back buffer") }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: row, destinationBytesPerImage: row * h)
        blit.endEncoding()
        command.addCompletedHandler { [model] _ in
            let data = Data(bytes: buffer.contents(), count: row * h)
            DispatchQueue.main.async { model.capture(bgra: data, width: w, height: h, metal: view) }
        }
    }
    #endif

    /// Encodes the present pass: to the view with the tone map, or unmapped
    /// into an RGBA16F target. During a switch with a transition it maps the
    /// transition's blend; otherwise it dissolves itself.
    private func composite(_ enc: MTLRenderCommandEncoder, tone: Bool) {
        guard let cur else { enc.endEncoding(); return }
        let t = Float(blendP)
        let blended = active != nil && out != nil && blendP > 0 ? mix : nil
        putPresent(0, model.vivid ? PaletteTour.vividSaturation : 1,
                   out == nil || blended != nil ? 1 : t * t * (3 - 2 * t), tone ? 1 : 0,
                   model.vivid ? PaletteTour.vividVibrance : 0)
        putPresent(presentPost, 0, 0, 0, 1)
        putPresent(presentPost + 16, Float(presentFrame % 16_777_216), 0, 0, 0)
        presentFrame &+= 1
        enc.setRenderPipelineState(tone ? present : presentHDR)
        // on screen with lyrics loaded, the lyric pass; the bake stays free of the layer
        if tone, model.lyrics != nil, let presentCdg, let lyrics, let layerSampler, let size = history.first {
            enc.setRenderPipelineState(presentCdg)
            layerBlock[0] = Float(size.width)
            layerBlock[1] = Float(size.height)
            layerBlock.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            enc.setFragmentTexture(lyrics.texture, index: 3)
            enc.setFragmentSamplerState(layerSampler, index: 1)
        }
        presentBlock.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.setFragmentTexture(blended ?? cur.targets[0], index: 0)
        enc.setFragmentTexture((out ?? cur).targets[0], index: 1)
        // the bake never reads the history, but every texture the function uses is bound
        enc.setFragmentTexture(tone ? history[0] : cur.targets[0], index: 2)
        enc.setFragmentTexture(cur.targets[0], index: 4)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Packs the OverlayUniforms after present0 for a w×h drawable presented at
    /// now: the tracked regions and the reduce-motion preference through
    /// oscillux_overlay_pack.
    private func packOverlay(_ w: Int, _ h: Int, _ now: CFTimeInterval) {
        let interval = lastPresent.map { min(max((now - $0) * 1000, 1e-3), 1000) } ?? 1000 / 60
        lastPresent = now
        let state = model.overlay
        var cfg = overlayConfig()
        cfg.viewport_width = Double(w)
        cfg.viewport_height = Double(h)
        cfg.frame_interval_ms = interval
        let count = min(state.regions.count, OverlayState.maxRegions)
        for (i, r) in state.regions.prefix(count).enumerated() {
            overlayRegions[i] = OscilluxOverlayRegion(x: r.x, y: r.y, width: r.width, height: r.height,
                                                      corner_radius: r.cornerRadius, feather: r.feather,
                                                      strength: r.strength, mode: r.mode, reserved: 0)
        }
        let ok = presentBlock.withUnsafeMutableBytes { block in
            let out = block.baseAddress!.advanced(by: presentHead).assumingMemoryBound(to: UInt8.self)
            return overlayRegions.withUnsafeBufferPointer {
                oscillux_overlay_pack(&cfg, $0.baseAddress, count, out, overlaySize) == OSCILLUX_OK
                    || oscillux_overlay_pack(&cfg, nil, 0, out, overlaySize) == OSCILLUX_OK
            }
        }
        if !ok { model.error = "overlay: the core refused the overlay config" }
    }

    private func putPresent(_ off: Int, _ x: Float, _ y: Float, _ z: Float, _ w: Float) {
        for (i, v) in [x, y, z, w].enumerated() {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { bytes in
                for j in 0..<4 { presentBlock[off + i * 4 + j] = bytes[j] }
            }
        }
    }

    /// The core's default overlay config with the reduce-motion preference.
    private func overlayConfig() -> OscilluxOverlayConfig {
        var cfg = OscilluxOverlayConfig()
        cfg.struct_size = UInt32(MemoryLayout<OscilluxOverlayConfig>.size)
        oscillux_overlay_config_default(&cfg)
        cfg.reduced_motion = model.overlay.reducedMotion ? 1 : 0
        return cfg
    }

    /// The intensity visuals present at, presentation1.x: halved under reduced motion.
    private var presentationIntensity: Float {
        var cfg = overlayConfig()
        var intensity = 1.0
        oscillux_overlay_presentation_intensity(&cfg, &intensity)
        return Float(intensity)
    }

    private static func makePipeline(_ device: MTLDevice, _ source: String, _ function: String) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: source + vertexSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "oscillux_vertex")
        guard let fragment = library.makeFunction(name: function) else {
            throw HostError("no Metal function \(function)")
        }
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private func makeTarget(_ w: Int, _ h: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)!
    }

    // VisualUniforms, std140 offsets from conformance/packing/visual-uniforms.schema.json;
    // host values as in hosts/web/host.js.
    private func pack(_ layer: Layer, _ w: Int, _ h: Int) {
        let v = layer.visual, tm = Double(layer.frame) * Renderer.dt
        putAudio(audio)
        put(0, Float(w)); put(4, Float(h)); put(8, Float(tm)); put(12, Float(Renderer.dt * Double(layer.stride)))
        put(44, 1)
        put(48, v.params[0]); put(52, v.params[1]); put(56, v.params[2])
        put(80, model.overlay.reducedMotion ? 0 : v.trailDecay)
        put4(96, 0.15, 0.9, 0.72, 1)
        put4(112, 0, 0, 0, 0)
        let p = model.vivid ? PaletteTour.palette(at: tm, offset: Double(v.palette[0])) : v.palette
        put4(128, p[0], p[1], p[2], p[3])
        put4(144, 0, 1, 0, 0)
        put4(160, presentationIntensity, Renderer.ladder[level].reduce, 0, 0)
        let safe = model.overlay.safeRect
        put4(176, safe.x, safe.y, safe.z, safe.w)
    }

    private func putAudio<A: AudioFeatures>(_ a: A) {
        put(16, Float(a.amplitude)); put(20, Float(a.bass)); put(24, Float(a.mid)); put(28, Float(a.treble))
        put(32, Float(a.beat)); put(36, Float(a.beatPhase)); put(40, Float(a.onset))
        put(60, Float(a.level)); put(64, Float(a.bassImpact)); put(68, Float(a.spectralCentroid)); put(72, Float(a.flux)); put(76, Float(a.beatCount))
        put(84, Float(a.barPhase)); put(88, Float(a.downbeat))
        for i in 0..<64 { put(192 + i * 4, Float(a.spectrum(i))) }
    }

    /// One reaction sample per stepped frame, which both layers of a switch read:
    /// the file at the frame's photon time, or the synthetic source's next step.
    private func sampleAudio(_ now: CFTimeInterval) {
        if let track = model.audio {
            audio = track.frame(photon: photonTime ?? now + Renderer.dt)
            return
        }
        if let mic = model.mic {
            audio = mic.frame(photon: photonTime ?? now + Renderer.dt)
            return
        }
        if synthetic == nil {
            do { synthetic = try SyntheticSource() } catch { model.error = error.localizedDescription }
        }
        audio = synthetic?.frame() ?? ReactionAudio()
        if beatTracePath != nil, beatTrace.count < model.stopAt, let s = synthetic {
            beatTrace.append((s.steps, audio.beatCount + audio.beatPhase, audio.beat, audio.locked, audio.tempo))
        }
    }

    private func writeBeatTrace(_ path: String) {
        guard !beatTrace.isEmpty else { return NSLog("beat trace: no synthetic-source frames to write") }
        let text = beatTrace.map {
            String(format: "%d %.17g %.17g %d %.17g", $0.steps, $0.position, $0.beat, $0.locked ? 1 : 0, $0.tempo)
        }.joined(separator: "\n") + "\n"
        do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch {
            NSLog("beat trace: %@", error.localizedDescription)
        }
    }

    private func put(_ off: Int, _ value: Float) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes in
            for i in 0..<4 { uniforms[off + i] = bytes[i] }
        }
    }
    private func put4(_ off: Int, _ x: Float, _ y: Float, _ z: Float, _ w: Float) {
        put(off, x); put(off + 4, y); put(off + 8, z); put(off + 12, w)
    }

    // The 64x64 gradient stand-in the render harnesses use for image input.
    private static func standInImage(_ device: MTLDevice) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
        desc.usage = [.shaderRead]
        let tex = device.makeTexture(descriptor: desc)!
        var px = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                px[i] = UInt8(clamping: Int(40 + Double(x) * 2.5))
                px[i + 1] = UInt8(clamping: Int(30 + Double(y) * 1.8))
                px[i + 2] = UInt8(clamping: Int(120 + ((x + y) & 15) * 6))
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: px, bytesPerRow: 64 * 4)
        return tex
    }
}
