import SwiftUI

/// Chooses between the launcher and the game surface. When an app is launched,
/// the launcher UI is replaced entirely by the game surface — matching the
/// "only the game surface, not Android OS UI" requirement.
struct RootView: View {
    @StateObject private var library = AppLibrary()
    @StateObject private var status = RendererStatus()
    @StateObject private var runtime = RuntimeStatus()

    var body: some View {
        Group {
            if let running = library.runningApp {
                GameSurfaceView(app: running, status: status) {
                    library.stop()
                }
            } else {
                LauncherView(library: library, status: status, runtime: runtime)
            }
        }
        .onAppear {
            if !library.launchFromCommandLineIfRequested() {
                library.refresh()
            }
        }
    }
}
