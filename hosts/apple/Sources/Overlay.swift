// SPDX-License-Identifier: AGPL-3.0-only
// Overlay regions for the SwiftUI host (OSC-OVERLAY), as hosts/web/overlay.js does for the
// page: views marked with .oscilluxOverlay report their frames, OverlayState turns them into
// viewport fractions, and Renderer packs them into the shared present pass's OverlayUniforms
// (oscillux_overlay_pack) with the platform's reduce-motion preference.
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the present pass does under a region: OSCILLUX_OVERLAY_MODE_* in oscillux.h.
struct OverlayMode: OptionSet, Equatable {
    let rawValue: UInt32
    /// Hold the visual at or below the ceiling for white text.
    static let lightText = OverlayMode(rawValue: 1)
    /// Hold the visual at or above the floor for black text.
    static let darkText = OverlayMode(rawValue: 2)
    static let desaturate = OverlayMode(rawValue: 4)
    static let blur = OverlayMode(rawValue: 8)
    static let dampMotion = OverlayMode(rawValue: 16)
    static let dampFlash = OverlayMode(rawValue: 32)
    /// Everything a light-text menu or caption wants.
    static let lightPanel: OverlayMode = [.lightText, .desaturate, .blur, .dampMotion, .dampFlash]
}

/// One marked view: its frame in global coordinates, its shape in points and its mode.
struct OverlayMark: Equatable {
    var frame: CGRect
    var mode: OverlayMode
    var cornerRadius: CGFloat
    var feather: CGFloat
    var strength: Double
}

struct OverlayMarksKey: PreferenceKey {
    static var defaultValue: [OverlayMark] = []
    static func reduce(value: inout [OverlayMark], nextValue: () -> [OverlayMark]) { value += nextValue() }
}

/// The frame, in global coordinates, of the view the visuals fill.
struct OverlayViewportKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {
    /// Marks this view as UI over the visuals: the present pass treats its frame as an overlay
    /// region. Shape values are in points.
    func oscilluxOverlay(_ mode: OverlayMode, cornerRadius: CGFloat = 0, feather: CGFloat = 0,
                         strength: Double = 1) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: OverlayMarksKey.self, value: [OverlayMark(
                frame: g.frame(in: .global), mode: mode, cornerRadius: cornerRadius, feather: feather,
                strength: strength)])
        })
    }

    /// Marks this view as the one the visuals fill, which regions are fractions of.
    func oscilluxViewport() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: OverlayViewportKey.self, value: g.frame(in: .global))
        })
    }

    /// Hands the marked frames under this view to state whenever the layout changes.
    func oscilluxOverlayTracking(_ state: OverlayState) -> some View {
        onPreferenceChange(OverlayMarksKey.self) { state.marks = $0 }
            .onPreferenceChange(OverlayViewportKey.self) { state.viewport = $0 }
    }
}

/// The overlay the renderer reads each frame. Not observable: a layout change updates it
/// without redrawing any view.
final class OverlayState {
    /// A region as oscillux_overlay_pack takes it: viewport fractions, origin top-left, with
    /// corner radius and feather in viewport heights.
    struct Region {
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        var cornerRadius = 0.0, feather = 0.0, strength = 0.0
        var mode: UInt32 = 0
    }
    static let maxRegions = 8

    var marks: [OverlayMark] = [] { didSet { refresh() } }
    var viewport: CGRect = .zero { didSet { refresh() } }
    private(set) var regions: [Region] = []
    /// The visuals' safe rectangle: (left, top, right, bottom) corners in viewport fractions.
    private(set) var safeRect = SIMD4<Float>(0.05, 0.05, 0.95, 0.95)
    /// The platform's reduce-motion preference, or the -reduceMotion launch argument.
    private(set) var reducedMotion = false
    private var observer: NSObjectProtocol?
    #if os(macOS)
    private let center = NSWorkspace.shared.notificationCenter
    private static let changed = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
    private static var platform: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    #else
    private let center = NotificationCenter.default
    private static let changed = UIAccessibility.reduceMotionStatusDidChangeNotification
    private static var platform: Bool { UIAccessibility.isReduceMotionEnabled }
    #endif

    init() {
        let forced = UserDefaults.standard.object(forKey: "reduceMotion") as? String
        let read = { forced.map { $0 == "yes" || $0 == "1" } ?? OverlayState.platform }
        reducedMotion = read()
        observer = center.addObserver(forName: OverlayState.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reducedMotion = read()
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    private func refresh() {
        let v = viewport
        guard v.width > 0, v.height > 0 else { regions = []; return }
        regions = marks.prefix(OverlayState.maxRegions).compactMap { m in
            guard m.frame.width > 0, m.frame.height > 0 else { return nil }
            return Region(x: (m.frame.minX - v.minX) / v.width, y: (m.frame.minY - v.minY) / v.height,
                          width: m.frame.width / v.width, height: m.frame.height / v.height,
                          cornerRadius: min(max(m.cornerRadius / v.height, 0), 1),
                          feather: min(max(m.feather / v.height, 0), 1),
                          strength: min(max(m.strength, 0), 1), mode: m.mode.rawValue)
        }
        safeRect = OverlayState.safeRect(regions)
    }

    /// The 5% margin, with each region moved out of it across the viewport edge that costs the
    /// least depth, as hosts/web/overlay.js safeRect does.
    static func safeRect(_ regions: [Region]) -> SIMD4<Float> {
        var s: [Double] = [0.05, 0.05, 0.95, 0.95]
        for r in regions {
            let gaps = [r.x, r.y, 1 - r.x - r.width, 1 - r.y - r.height]
            let depths = gaps.enumerated().map { ($0.offset % 2 == 0 ? r.width : r.height) + max($0.element, 0) }
            let edge = depths.firstIndex(of: depths.min()!)!
            let depth = min(depths[edge], 0.5)
            s[edge] = edge < 2 ? max(s[edge], depth) : min(s[edge], 1 - depth)
        }
        return SIMD4<Float>(Float(s[0]), Float(s[1]), Float(s[2]), Float(s[3]))
    }
}

/// The text the host shows over the visuals: the visual's title as a light-text caption and a
/// dark-text badge, each an overlay region.
struct OverlayCaptions: View {
    let title: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold)).foregroundStyle(.white)
                Text("Text over the visual, held at 4.5:1 against white").font(.caption)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .oscilluxOverlay([.lightText, .desaturate, .dampMotion, .dampFlash], cornerRadius: 6, feather: 12)
            Spacer(minLength: 16)
            Text("Dark text, 4.5:1 against black").font(.callout.weight(.semibold)).foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .oscilluxOverlay([.darkText, .dampFlash], cornerRadius: 12)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}
