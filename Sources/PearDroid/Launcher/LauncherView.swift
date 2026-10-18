import SwiftUI
import AppKit

/// The native launcher: enumerates installed APKs and launches one onto the
/// game surface. Android itself never draws a UI — only the selected app's
/// surface is shown.
struct LauncherView: View {
    @ObservedObject var library: AppLibrary
    @ObservedObject var status: RendererStatus
    @ObservedObject var runtime: RuntimeStatus
    @State private var selection: ApkInfo.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PearDroid")
                    .font(.title2)
                    .bold()
                Text("Android compatibility layer · native launcher")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(status.deviceName)
                    .font(.callout)
                    .monospaced()
                Text("\(library.apps.count) app\(library.apps.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: runtimeSymbol)
                        .foregroundStyle(runtimeTint)
                    Text("runtime: \(runtime.summary)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .help(runtime.detail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var runtimeSymbol: String {
        switch runtime.state {
        case .ready: return "cpu.fill"
        case .denied: return "xmark.circle.fill"
        }
    }

    private var runtimeTint: Color {
        switch runtime.state {
        case .ready: return .green
        case .denied: return .red
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.apps.isEmpty {
            emptyState
        } else {
            List(library.apps, selection: $selection) { app in
                AppRow(app: app) { library.launch(app) }
            }
            .listStyle(.inset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No APKs found")
                .font(.title3)
            Text("Drop Android packages into the PearDroid APK folder, then scan again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(library.apkDirectory.path)
                .font(.caption)
                .monospaced()
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            HStack {
                Button("Open APK folder") { library.revealApkFolder() }
                Button("Scan again") { library.refresh() }
                    .keyboardShortcut("r")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error = status.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if library.isScanning {
                Label("Scanning…", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
            } else {
                Label("Game surface ready · MoltenVK", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rescan") { library.refresh() }
                .controlSize(.small)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct AppRow: View {
    let app: ApkInfo
    let launch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(app.packageId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let version = app.versionName {
                    Text("v\(version)")
                        .font(.caption)
                        .monospacedDigit()
                }
                Text(app.formattedSize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("Launch", action: launch)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
