import AppKit
import SwiftUI

/// The strip is an NSStatusItem with an NSPopover, not a SwiftUI MenuBarExtra:
/// MenuBarExtra rebuilds its button whenever the label changes, and the strip
/// changes every refresh, which kept the panel from ever staying open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var store: Store!

    func applicationDidFinishLaunching(_ notification: Notification) {
        PrintMode.runIfAsked()
        // A menu-bar app: no Dock icon, even when launched with `swift run`.
        NSApp.setActivationPolicy(.accessory)

        if Installer.offerMoveIfNeeded() { return }
        store = Store.shared
        RenderMode.runIfAsked(store)
        Installer.applyLoginDefault(store)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            stripView.frame = button.bounds
            stripView.autoresizingMask = [.width, .height]
            button.addSubview(stripView)
        }
        showStrip(store.stripImage)
        store.isStripVisible = { [weak self] in
            self?.statusItem.button?.window?.occlusionState.contains(.visible) ?? false
        }
        store.onStripChange = { [weak self] image, label in
            self?.showStrip(image)
            if self?.statusItem.button?.accessibilityLabel() != label { self?.statusItem.button?.setAccessibilityLabel(label) }
        }

        let host = NSHostingController(rootView: CockpitView().environment(store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        applyTheme(store.theme)
        store.onThemeChange = { [weak self] in self?.applyTheme($0) }

        // `--show` / `--show-setup`: open the panel once the first numbers are
        // in, for screenshots of the real thing.
        let args = CommandLine.arguments
        if args.contains("--show") || args.contains("--show-setup") {
            store.showingSetup = args.contains("--show-setup")
            // A transient popover closes as soon as the app is not frontmost.
            popover.behavior = .applicationDefined
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, let button = self.statusItem.button else { return }
                self.togglePanel(button)
            }
        }
    }

    /// The strip draws in its own view: a new frame only repaints it, while
    /// replacing the button's image would re-lay-out the status item every
    /// frame. The item is resized only when the strip's width changes.
    private let stripView = StripView()

    private func showStrip(_ image: NSImage) {
        let length = ceil(image.size.width) + 8
        if statusItem.length != length { statusItem.length = length }
        stripView.image = image
    }

    /// The popover's own chrome (its arrow and edge) follows the panel theme.
    private func applyTheme(_ theme: PanelTheme) {
        switch theme {
        case .dark: popover.appearance = NSAppearance(named: .darkAqua)
        case .light: popover.appearance = NSAppearance(named: .aqua)
        case .system: popover.appearance = nil
        }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // Right click is the middle click of a Mac trackpad: refresh without opening.
        if NSApp.currentEvent?.type == .rightMouseUp {
            store.panelOpened()
            store.refreshLimits(force: true)
            return
        }
        store.panelOpened()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // Key focus, so R refreshes and Esc closes.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }
}

/// Draws the latest strip image centred; clicks pass through to the button.
final class StripView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let s = image.size
        image.draw(in: NSRect(x: ((bounds.width - s.width) / 2).rounded(), y: ((bounds.height - s.height) / 2).rounded(),
                              width: s.width, height: s.height))
    }
}
