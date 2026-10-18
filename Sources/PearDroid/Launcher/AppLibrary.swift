import Foundation
import AppKit

/// Holds the set of discovered APKs and which one (if any) is currently being
/// presented on the game surface.
@MainActor
final class AppLibrary: ObservableObject {
    @Published private(set) var apps: [ApkInfo] = []
    @Published private(set) var isScanning = false
    @Published private(set) var error: String?
    @Published private(set) var apkDirectory: URL
    @Published var runningApp: ApkInfo?

    init(apkDirectory: URL = ApkScanner.defaultDirectory()) {
        self.apkDirectory = apkDirectory
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let directory = apkDirectory
        Task.detached(priority: .userInitiated) {
            let found = ApkScanner.scan(directory: directory)
            await MainActor.run {
                self.apps = found
                self.isScanning = false
                self.error = nil
            }
        }
    }

    /// Supports `PearDroid --apk <path>` so a package can be opened directly
    /// (useful for automation and for a future "Open With" association).
    @discardableResult
    func launchFromCommandLineIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--apk"), flag + 1 < arguments.count else {
            return false
        }
        let url = URL(fileURLWithPath: arguments[flag + 1])
        guard let info = ApkScanner.inspect(url) else { return false }
        apps = [info]
        runningApp = info
        return true
    }

    func chooseDirectory(_ url: URL) {
        apkDirectory = url
        refresh()
    }

    func revealApkFolder() {
        ApkScanner.ensureDirectory(apkDirectory)
        NSWorkspace.shared.activateFileViewerSelecting([apkDirectory])
    }

    func launch(_ app: ApkInfo) {
        runningApp = app
    }

    func stop() {
        runningApp = nil
    }
}
