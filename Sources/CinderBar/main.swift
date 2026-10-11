import AppKit

// A plain AppKit entry point. A SwiftUI `App` must declare a scene, and the
// only windowless-looking one (Settings) still opens an empty window when a
// menu-bar app activates. SwiftUI is used inside the panel only.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
