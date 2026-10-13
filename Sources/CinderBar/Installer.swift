import AppKit
import ServiceManagement

/// Puts the app where it belongs: in /Applications, opening at login.
///
/// Opened from anywhere else (Downloads, a build folder), it offers to move
/// itself and relaunch from there. A downloaded app that macOS has
/// translocated runs from a random read-only copy, so the original path is
/// asked of the Security framework first.
@MainActor
enum Installer {
    static let destination = URL(fileURLWithPath: "/Applications/Cinder Bar.app")
    private static let dontAskKey = "dontOfferMoveToApplications"
    private static let loginDefaultKey = "loginItemDefaultApplied"

    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(user + "/")
    }

    /// Returns true when the app is relaunching from /Applications and this
    /// instance should stop.
    static func offerMoveIfNeeded() -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", !isInApplications,
              !UserDefaults.standard.bool(forKey: dontAskKey),
              !CommandLine.arguments.contains("--no-move") else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Cinder Bar to Applications?"
        alert.informativeText = "Cinder Bar lives in the menu bar and opens at login. It works best from the Applications folder."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.icon = NSApp.applicationIconImage
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: dontAskKey) }
        guard answer == .alertFirstButtonReturn else { return false }

        do {
            try move(from: originalURL(of: bundle))
            relaunch()
            return true
        } catch {
            let fail = NSAlert()
            fail.messageText = "Could not move Cinder Bar"
            fail.informativeText = "\(error.localizedDescription)\n\nDrag Cinder Bar.app into the Applications folder yourself."
            fail.runModal()
            return false
        }
    }

    private static func move(from source: URL) throws {
        let fm = FileManager.default
        // An older copy goes to the Trash, not away for good.
        if fm.fileExists(atPath: destination.path) {
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: destination)
        // Downloaded copies carry the quarantine flag; the user has just chosen to keep this one.
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        x.arguments = ["-dr", "com.apple.quarantine", destination.path]
        try? x.run()
        x.waitUntilExit()
        // The copy left behind would otherwise launch an old version later.
        if source.standardizedFileURL != destination.standardizedFileURL {
            try? fm.trashItem(at: source, resultingItemURL: nil)
        }
    }

    private static func relaunch() {
        // Wait for this instance to quit, so the new one owns the status item.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", destination.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// The path the user actually opened, behind App Translocation.
    private static func originalURL(of url: URL) -> URL {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSym = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return url }
        let isTranslocated = unsafeBitCast(isSym, to: IsTranslocated.self)
        let original = unsafeBitCast(origSym, to: OriginalPath.self)
        var translocated: DarwinBoolean = false
        guard isTranslocated(url as CFURL, &translocated, nil).boolValue, translocated.boolValue,
              let orig = original(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return orig as URL
    }

    /// Opening at login is on by default, once, the first time the app runs
    /// from Applications. Turning it off in SETUP sticks.
    static func applyLoginDefault(_ store: Store) {
        guard isInApplications, !UserDefaults.standard.bool(forKey: loginDefaultKey) else { return }
        UserDefaults.standard.set(true, forKey: loginDefaultKey)
        if SMAppService.mainApp.status != .enabled { store.setLaunchAtLogin(true) }
    }
}
