// SPDX-License-Identifier: AGPL-3.0-only
// SwiftUI reference host (macOS + iOS) for a bundled visual set. Launch
// arguments mirror hosts/web's query: -visual <id>, -frames <N> (stop after N
// frames), -size <W>x<H> (fixed render size instead of the view's),
// -colour vivid|manifest (palette tour and saturation, or the manifest palette),
// -quality auto|0..3 (governed or fixed quality level; auto unless -size or
// -frames is given, which pin the top level), -transition auto|<id> (cycle
// through the switch transitions, or always use one), -audio <path> (play an
// audio file and drive the visuals from its Oscillux DSP analysis), -cdg <path>
// (CD+G lyrics over the visuals, on the audio's clock; a .cdg beside the audio
// file loads with it otherwise), -cdgkey auto|preset|table|none|index:<N>|mask:<hex>
// (the colours that show the visual beneath; auto by default, the colours of the
// window's edge), -karaoke <path> (an MP3+G .zip: its song and .cdg together,
// KaraokeZip.swift; -audio and -cdg take one too), -type <id> and -intensity <id>
// (show only the visuals of that type and intensity, hosts/categories.json) and,
// on macOS, -capture <path>
// with -frames (write the window, visuals and UI together, to a PNG after the last
// frame and quit; it needs no display or screen recording).
// The audio menu also takes the microphone (Microphone.swift); on macOS a .zip, .cdg or audio
// file dropped on the window opens as the web host's drop does.
import AVFoundation
import MetalKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import ImageIO
#endif

/// The status line, apart from HostModel so that updating it every few frames
/// re-renders only its own text, not the controls.
final class StatusModel: ObservableObject { @Published var text = "" }

final class HostModel: ObservableObject {
    @Published var selection = ""
    /// The type and intensity filters, "" for all: the picker, step and the warmed
    /// neighbours cover only the visuals in `listed`.
    @Published var type = "" { didSet { refilter() } }
    @Published var intensity = "" { didSet { refilter() } }
    @Published var paused = false {
        didSet { if paused { audio?.pause() } else { audio?.play() } }
    }
    @Published var restartToken = 0
    @Published var vivid = true
    /// The transition for switches, or "auto" to cycle through them all.
    @Published var transition = "auto"
    @Published var error: String?
    /// The playing file, or nil for the microphone or the synthetic source.
    @Published private(set) var audio: AudioTrack?
    @Published private(set) var loadingAudio: String?
    /// The live microphone, or nil.
    @Published private(set) var mic: MicSource?
    /// The CD+G lyrics over the visuals, and their key. Another song replaces them with its own
    /// (its sidecar) or none, and closing the song drops them.
    @Published private(set) var lyrics: CdgStream?
    let cdgKey = CdgKey(UserDefaults.standard.string(forKey: "cdgkey"))
    let status = StatusModel()
    /// The UI over the visuals and the reduce-motion preference, for the present pass.
    let overlay = OverlayState()
    let bundle: VisualBundle?
    let stopAt: Int
    let fixedSize: CGSize?
    /// A fixed quality level, or nil when the governor picks it.
    let pinnedQuality: Int?
    /// Where -capture writes the window after the last of -frames, or nil.
    let capturePath: String?

    init() {
        let defaults = UserDefaults.standard
        stopAt = defaults.object(forKey: "frames") == nil ? .max : defaults.integer(forKey: "frames")
        #if os(macOS)
        capturePath = stopAt == .max ? nil : defaults.string(forKey: "capture")
        #else
        capturePath = nil
        #endif
        let size = (defaults.string(forKey: "size") ?? "").split(separator: "x").compactMap { Int($0) }
        fixedSize = size.count == 2 ? CGSize(width: size[0], height: size[1]) : nil
        vivid = defaults.string(forKey: "colour") != "manifest"
        transition = defaults.string(forKey: "transition") ?? "auto"
        let quality = defaults.string(forKey: "quality")
        if let q = quality.flatMap(Int.init), (0...3).contains(q) {
            pinnedQuality = q
        } else {
            pinnedQuality = quality != "auto" && (fixedSize != nil || stopAt != .max) ? 3 : nil
        }
        do {
            let b = try VisualBundle.load()
            bundle = b
            let wanted = defaults.string(forKey: "visual")
            type = b.types.first(where: { $0.id == defaults.string(forKey: "type") })?.id ?? ""
            intensity = b.intensities.first(where: { $0.id == defaults.string(forKey: "intensity") })?.id ?? ""
            if !any(type, intensity) { intensity = "" }
            selection = listed.first(where: { $0.id == wanted })?.id ?? listed.first?.id ?? ""
        } catch {
            bundle = nil
            self.error = error.localizedDescription
        }
        let cdg = defaults.string(forKey: "cdg")
        if let cdg { openLyrics(URL(fileURLWithPath: cdg)) }
        if let path = defaults.string(forKey: "audio") { openAudio(URL(fileURLWithPath: path), sidecar: cdg == nil) }
        if let path = defaults.string(forKey: "karaoke") { openKaraoke(URL(fileURLWithPath: path)) }
    }

    func restart() {
        restartToken += 1
        audio?.restart()
    }

    /// Decodes and analyses `url` off the main thread, then plays it unless paused. With
    /// `sidecar`, a .cdg of the same name beside it loads as its lyrics.
    func openAudio(_ url: URL, sidecar: Bool = true) {
        if Self.isZip(url) { return openKaraoke(url) }
        loadingAudio = url.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            // a picked file outside the app's container is readable only inside its security scope
            let scoped = url.startAccessingSecurityScopedResource()
            let result = Result { try AudioTrack(url: url) }
            if scoped { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async { [self] in
                loadingAudio = nil
                switch result {
                case .success(let track):
                    play(track)
                    let cdg = url.deletingPathExtension().appendingPathExtension("cdg")
                    if sidecar {
                        if FileManager.default.fileExists(atPath: cdg.path) { openLyrics(cdg) } else { lyrics = nil }
                    }
                case .failure(let e):
                    error = "\(url.lastPathComponent): \(e.localizedDescription)"
                }
            }
        }
    }

    /// Opens an MP3+G .zip (KaraokeZip.swift) off the main thread: its song, read from a
    /// temporary file deleted once decoded, as the audio and its .cdg as the lyrics. Nothing
    /// shown changes unless both open.
    func openKaraoke(_ url: URL) {
        loadingAudio = url.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = url.startAccessingSecurityScopedResource()
            let result = Result { () -> (AudioTrack, CdgStream) in
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let k = try KaraokeZip(url: url)
                let lyrics = try CdgStream(data: k.cdg, name: k.cdgName)
                return (try k.withAudioFile { try AudioTrack(url: $0, name: k.audioName) }, lyrics)
            }
            DispatchQueue.main.async { [self] in
                loadingAudio = nil
                switch result {
                case .success(let (track, cdg)):
                    play(track)
                    lyrics = cdg
                case .failure(let e):
                    error = "\(url.lastPathComponent): \(e.localizedDescription)"
                }
            }
        }
    }

    /// Opens dropped files as the web host does: a .zip as karaoke, else a .cdg as the lyrics
    /// and an audio file as the song (with the .cdg dropped beside it, not its sidecar).
    func openDropped(_ urls: [URL]) -> Bool {
        if let zip = urls.first(where: Self.isZip) { openKaraoke(zip); return true }
        let cdg = urls.first { $0.pathExtension.lowercased() == "cdg" }
        let song = urls.first { $0 != cdg && (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) ?? false) }
        if let cdg { openLyrics(cdg) }
        if let song { openAudio(song, sidecar: cdg == nil) }
        return cdg != nil || song != nil
    }

    static func isZip(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    private func play(_ track: AudioTrack) {
        audio?.pause()
        audio = track
        mic = nil
        error = nil
        if !paused { track.play() }
    }

    /// Asks for the record permission, then replaces the file or synthetic source with the
    /// microphone.
    func openMic() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { [self] in
                guard granted else {
                    error = "Microphone access is off: allow it in Settings to react to the room"
                    return
                }
                closeAudio()
                do {
                    mic = try MicSource()
                    error = nil
                } catch {
                    self.error = "Microphone: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Back to the synthetic source.
    func closeAudio() {
        audio?.pause()
        audio = nil
        mic = nil
        lyrics = nil
    }

    /// Loads `url` as the lyrics (an MP3+G .zip opens as karaoke); a refused stream keeps the
    /// ones shown.
    func openLyrics(_ url: URL) {
        if Self.isZip(url) { return openKaraoke(url) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            lyrics = try CdgStream(url: url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    #if os(macOS)
    /// Writes the window as it shows to capturePath, then quits. The visuals are the present
    /// pass's last frame (BGRA8, from Renderer); AppKit cannot draw a Metal layer, so the view
    /// hierarchy is drawn in process with the Metal view hidden and laid over that frame.
    func capture(bgra: Data, width: Int, height: Int, metal: NSView) {
        defer { NSApp.terminate(nil) }
        guard let path = capturePath, let content = metal.window?.contentView else { return NSLog("capture: no window") }
        let bounds = content.bounds
        metal.isHidden = true
        let ui = content.bitmapImageRepForCachingDisplay(in: bounds)
        if let ui { content.cacheDisplay(in: bounds, to: ui) }
        metal.isHidden = false
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let order = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ui, let uiImage = ui.cgImage, let provider = CGDataProvider(data: bgra as CFData),
              let frame = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: order),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: ui.pixelsWide, height: ui.pixelsHigh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSLog("capture: could not draw the window") }
        let sx = CGFloat(ui.pixelsWide) / bounds.width, sy = CGFloat(ui.pixelsHigh) / bounds.height
        var r = metal.convert(metal.bounds, to: content)
        if content.isFlipped { r.origin.y = bounds.height - r.maxY }
        let all = CGRect(x: 0, y: 0, width: ui.pixelsWide, height: ui.pixelsHigh)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(all)
        ctx.draw(frame, in: CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy))
        ctx.draw(uiImage, in: all)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return NSLog("capture: cannot write %@", path) }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) {
            NSLog("capture: wrote %@ (%dx%d, visuals %dx%d)", path, ui.pixelsWide, ui.pixelsHigh, width, height)
        } else {
            NSLog("capture: cannot write %@", path)
        }
    }
    #endif

    var title: String { bundle?.visuals.first(where: { $0.id == selection })?.title ?? "" }

    var listed: [VisualBundle.Visual] { bundle?.visuals.filter { matches($0, type, intensity) } ?? [] }

    private func matches(_ v: VisualBundle.Visual, _ type: String, _ intensity: String) -> Bool {
        (type.isEmpty || v.type == type) && (intensity.isEmpty || v.intensity == intensity)
    }

    /// Whether any visual has this type and intensity.
    func any(_ type: String, _ intensity: String) -> Bool {
        bundle?.visuals.contains { matches($0, type, intensity) } ?? false
    }

    /// Drops the intensity when the type has none of it, and keeps the visual when it still
    /// matches the filters, otherwise switches to the first that does.
    private func refilter() {
        if !any(type, intensity) { intensity = ""; return }
        let visuals = listed
        if !visuals.contains(where: { $0.id == selection }), let first = visuals.first { selection = first.id }
    }

    func step(_ d: Int) {
        let visuals = listed
        guard let i = visuals.firstIndex(where: { $0.id == selection }) else {
            if let first = visuals.first { selection = first.id }
            return
        }
        selection = visuals[(i + d + visuals.count) % visuals.count].id
    }
}

@main
struct OscilluxHostApp: App {
    @StateObject private var model = HostModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: HostModel
    @State private var importing = false
    /// What the file importer opens: lyrics, or else audio.
    @State private var importLyrics = false
    private static let cdg = UTType(filenameExtension: "cdg") ?? .data

    var body: some View {
        ZStack(alignment: .bottom) {
            // a capture lays the visuals' frame under the drawn hierarchy, which this would cover
            if model.capturePath == nil { Color.black.ignoresSafeArea() }
            // The viewport is reported inside the safe-area-ignoring frame: the visuals fill the
            // window under the title bar, so regions are fractions of that whole extent.
            MetalView(model: model).oscilluxViewport().ignoresSafeArea()
            if let error = model.error {
                Text(error).font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            OverlayCaptions(title: model.title)
            controls
        }
        .oscilluxOverlayTracking(model.overlay)
        .fileImporter(isPresented: $importing, allowedContentTypes: importLyrics ? [Self.cdg, .zip] : [.audio, .zip]) { result in
            switch result {
            case .success(let url): if importLyrics { model.openLyrics(url) } else { model.openAudio(url) }
            case .failure(let e): model.error = e.localizedDescription
            }
        }
        #if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in model.openDropped(urls) }
        .frame(minWidth: 480, minHeight: 320)
        #endif
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            // one row where it fits, as on a Mac or an iPad; two on a phone
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { filters; navigation; options; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { filters }
                    HStack(spacing: 8) { navigation }
                    HStack(spacing: 8) { options }
                }
            }
            Text(model.title).lineLimit(1).opacity(0.8)
            StatusLine(status: model.status)
        }
        .font(.callout)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .oscilluxOverlay(.lightPanel, cornerRadius: 8)
        .padding(12)
    }

    private var source: String {
        if let name = model.loadingAudio { return "Analysing \(name)…" }
        if let track = model.audio { return track.name }
        return model.mic != nil ? "Microphone" : "Synthetic"
    }

    @ViewBuilder private var filters: some View {
        Picker("Type", selection: $model.type) {
            Text("All types").tag("")
            ForEach(model.bundle?.types ?? [], id: \.id) { t in
                Text(t.label).tag(t.id).disabled(!model.any(t.id, model.intensity))
            }
        }
        .labelsHidden()
        .fixedSize()
        Picker("Intensity", selection: $model.intensity) {
            Text("Any intensity").tag("")
            ForEach(model.bundle?.intensities ?? [], id: \.id) { i in
                Text(i.label).tag(i.id).disabled(!model.any(model.type, i.id))
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder private var navigation: some View {
        Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
        Picker("Visual", selection: $model.selection) {
            ForEach(model.listed, id: \.id) { Text($0.id).tag($0.id) }
        }
        .labelsHidden()
        .fixedSize()
        Button { model.step(1) } label: { Image(systemName: "chevron.right") }
        Button { model.paused.toggle() } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill") }
        Button { model.restart() } label: { Image(systemName: "arrow.counterclockwise") }
    }

    @ViewBuilder private var options: some View {
        Button(model.vivid ? "Vivid" : "Manifest") { model.vivid.toggle() }
        Picker("Transition", selection: $model.transition) {
            Text("auto").tag("auto")
            ForEach(model.bundle?.transitions ?? [], id: \.id) { Text($0.id).tag($0.id) }
        }
        .labelsHidden()
        .fixedSize()
        Menu {
            Button("Open audio…") { importLyrics = false; importing = true }
            Button("Microphone") { model.openMic() }
            Button("Synthetic") { model.closeAudio() }
                .disabled(model.audio == nil && model.mic == nil)
            Divider()
            Button(model.lyrics.map { "Lyrics: \($0.name)" } ?? "Lyrics…") { importLyrics = true; importing = true }
        } label: {
            Text(source).lineLimit(1).truncationMode(.middle)
        }
        .disabled(model.loadingAudio != nil)
        .help("The audio the visuals react to, and CD+G lyrics over them")
    }
}

struct StatusLine: View {
    @ObservedObject var status: StatusModel
    var body: some View { Text(status.text).monospacedDigit().opacity(0.7) }
}

/// Holds the renderer: MTKView keeps only a weak reference to its delegate.
/// It also drives the view from a display link, so the renderer knows when
/// each frame will be on screen (Reaction.swift samples audio there).
final class RendererHolder: NSObject {
    var renderer: Renderer?
    weak var view: MTKView?
    var link: CADisplayLink?
    var timer: Timer?
    @objc func tick(_ link: CADisplayLink) {
        renderer?.photonTime = link.targetTimestamp
        view?.draw()
    }
}

#if os(macOS)
struct MetalView: NSViewRepresentable {
    let model: HostModel
    func makeCoordinator() -> RendererHolder { RendererHolder() }
    func makeNSView(context: Context) -> MTKView { makeView(model, context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) {}
}
#else
struct MetalView: UIViewRepresentable {
    let model: HostModel
    func makeCoordinator() -> RendererHolder { RendererHolder() }
    func makeUIView(context: Context) -> MTKView { makeView(model, context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) {}
}
#endif

private func makeView(_ model: HostModel, _ holder: RendererHolder) -> MTKView {
    let view = MTKView()
    view.colorPixelFormat = .bgra8Unorm
    view.preferredFramesPerSecond = 60
    view.framebufferOnly = true
    if let size = model.fixedSize {
        view.autoResizeDrawable = false
        view.drawableSize = size
    }
    guard let device = MTLCreateSystemDefaultDevice() else {
        model.error = "Metal is not available"
        return view
    }
    view.device = device
    do {
        holder.renderer = try Renderer(device: device, view: view, model: model)
        view.delegate = holder.renderer
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        holder.view = view
        #if os(macOS)
        if model.capturePath != nil {
            // a display link does not fire without a display, such as on a locked screen
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak holder] _ in holder?.view?.draw() }
            RunLoop.main.add(timer, forMode: .common)
            holder.timer = timer
            return view
        }
        let link = view.displayLink(target: holder, selector: #selector(RendererHolder.tick(_:)))
        #else
        let link = CADisplayLink(target: holder, selector: #selector(RendererHolder.tick(_:)))
        #endif
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        holder.link = link
    } catch {
        model.error = error.localizedDescription
    }
    return view
}
