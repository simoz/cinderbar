import AppKit
import SwiftUI

@main
struct EmberApp: App {
    // One store for the life of the app. (SwiftUI's @State is a macro on
    // this SDK, and the Command Line Tools ship no SwiftUI macro plugin.)
    private let store = Store.shared

    init() {
        PrintMode.runIfAsked()
        // A menu-bar app: no Dock icon, even when launched with `swift run`.
        NSApplication.shared.setActivationPolicy(.accessory)
        RenderMode.runIfAsked(store)
    }

    var body: some Scene {
        MenuBarExtra {
            CockpitView()
                .environment(store)
        } label: {
            Image(nsImage: store.stripImage)
                .accessibilityLabel(store.chip?.text ?? "Ember")
        }
        .menuBarExtraStyle(.window)
    }
}
