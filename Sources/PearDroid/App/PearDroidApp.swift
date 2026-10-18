import SwiftUI
import AppKit

@main
struct PearDroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("PearDroid") {
            RootView()
        }
        .defaultSize(width: 900, height: 640)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        pdLog("applicationDidFinishLaunching")
        // Ensure the process behaves like a regular GUI app even when the
        // executable is launched directly from the terminal during development.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
