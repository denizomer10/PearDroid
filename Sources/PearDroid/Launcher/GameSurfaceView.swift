import SwiftUI

/// Presents *only* the game surface for a launched app — no Android OS UI.
/// The MoltenVK-backed surface fills the window; a thin overlay provides the
/// app identity and a way back to the launcher.
struct GameSurfaceView: View {
    let app: ApkInfo
    @ObservedObject var status: RendererStatus
    let onExit: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            VulkanSurfaceView(status: status)
            overlay
        }
        .frame(minWidth: 640, minHeight: 400)
    }

    private var overlay: some View {
        HStack(spacing: 10) {
            Button(action: onExit) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName)
                    .font(.callout)
                    .bold()
                Text(app.packageId)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(String(format: "%.0f fps", status.framesPerSecond))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }
}
