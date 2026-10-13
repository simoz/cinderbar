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
            button.image = store.stripImage
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        store.onStripChange = { [weak self] image, label in
            self?.statusItem.button?.image = image
            self?.statusItem.button?.setAccessibilityLabel(label)
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
