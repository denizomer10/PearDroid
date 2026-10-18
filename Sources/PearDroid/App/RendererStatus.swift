import Foundation
import Metal

/// Observable state surfaced from the native renderer into the SwiftUI layer.
@MainActor
final class RendererStatus: ObservableObject {
    /// The Metal device reported up-front so the launcher can display it before
    /// a Vulkan surface exists.
    @Published var deviceName: String = MTLCreateSystemDefaultDevice()?.name ?? "unknown GPU"
    @Published var framesPerSecond: Double = 0
    @Published var error: String?
}
