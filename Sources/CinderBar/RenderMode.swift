import AppKit
import SwiftUI

/// `CinderBar --render DIR`: waits for one collector run and one limits probe,
/// then writes strip.png and cockpit.png. For screenshots and checking the UI
/// without a screen recording permission.
enum RenderMode {
    @MainActor
    static func runIfAsked(_ store: Store) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let setup = args.contains("--setup")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            await store.refresh()
            store.showingSetup = setup
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            write(store.stripImage, scale: 4, to: dir.appendingPathComponent("strip.png"))
            // `--frames`: the strip's motion as a few stills, the first with every lane flashing.
            if args.contains("--frames") {
                for i in 0..<6 {
                    var m = StripMotion(enabled: true, ember: Double(i) * 0.84, drift: Double(i) * 0.075, pulseMs: Double(i) * 300)
                    if i < 2 { for a in store.lanes { m.flash[a] = i == 0 ? 1 : 0.4 } }
                    let img = StripRenderer.image(snapshot: store.snapshot, lanes: store.lanes, standings: store.advice.standings,
                                                  chip: store.chip, fault: false, motion: m)
                    write(img, scale: 4, to: dir.appendingPathComponent("strip-frame-\(i).png"))
                }
            }
            for scheme in [ColorScheme.dark, .light] {
                let view = CockpitView().environment(store)
                    .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
                    .environment(\.colorScheme, scheme)
                let r = ImageRenderer(content: view)
                r.scale = 2
                if let img = r.nsImage {
                    write(img, scale: 1, to: dir.appendingPathComponent(setup ? "setup-\(scheme).png" : "cockpit-\(scheme).png"))
                }
            }
            exit(0)
        }
    }

    static func write(_ image: NSImage, scale: CGFloat, to url: URL) {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
