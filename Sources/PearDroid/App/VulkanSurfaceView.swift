import SwiftUI
import AppKit
import QuartzCore
import Metal

/// Bridges the SwiftUI view tree to a real `CAMetalLayer` and drives the Vulkan
/// renderer against it.
struct VulkanSurfaceView: NSViewRepresentable {
    let status: RendererStatus

    func makeNSView(context: Context) -> MetalCanvasView {
        let view = MetalCanvasView()
        view.status = status
        return view
    }

    func updateNSView(_ nsView: MetalCanvasView, context: Context) {
        nsView.status = status
    }
}

/// An `NSView` whose backing layer is a `CAMetalLayer`. MoltenVK presents the
/// Vulkan swapchain straight into this layer, which is what makes a translated
/// Vulkan surface appear inside an ordinary AppKit/SwiftUI hierarchy.
final class MetalCanvasView: NSView {
    weak var status: RendererStatus?

    private var renderer: VulkanRenderer?
    private var timer: Timer?
    private var frameCount = 0
    private var lastFPSUpdate = CFAbsoluteTimeGetCurrent()
    private var loggedFirstFrame = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
        return metalLayer
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startRendering()
        } else {
            stopRendering()
        }
    }

    override func layout() {
        super.layout()
        metalLayer?.contentsScale = window?.backingScaleFactor ?? 2.0
        updateDrawableSize()
    }

    // MARK: - Sizing

    private func pixelSize() -> (width: Int, height: Int) {
        let scale = window?.backingScaleFactor ?? 2.0
        return (Int((bounds.width * scale).rounded()), Int((bounds.height * scale).rounded()))
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        let size = pixelSize()
        guard size.width > 0, size.height > 0 else { return }

        if let renderer {
            renderer.resize(width: size.width, height: size.height)
        } else {
            metalLayer.drawableSize = CGSize(width: size.width, height: size.height)
            createRendererIfNeeded()
        }
    }

    // MARK: - Rendering

    private func createRendererIfNeeded() {
        guard renderer == nil, let metalLayer else { return }
        let size = pixelSize()
        guard size.width > 0, size.height > 0 else { return }

        pdLog("creating renderer for drawable \(size.width)x\(size.height)")
        metalLayer.drawableSize = CGSize(width: size.width, height: size.height)
        do {
            let renderer = try VulkanRenderer(layer: metalLayer)
            self.renderer = renderer
            status?.deviceName = renderer.deviceName
            status?.error = nil
            pdLog("renderer ready on \(renderer.deviceName)")
        } catch {
            status?.error = "\(error)"
            pdLog("renderer init failed: \(error)")
        }
    }

    private func startRendering() {
        createRendererIfNeeded()
        guard timer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopRendering() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let renderer else {
            createRendererIfNeeded()
            return
        }

        do {
            try renderer.drawFrame()
            status?.error = nil
            if !loggedFirstFrame {
                loggedFirstFrame = true
                pdLog("first frame presented")
            }
        } catch {
            status?.error = "\(error)"
            pdLog("drawFrame failed: \(error)")
        }

        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastFPSUpdate >= 1.0 {
            status?.framesPerSecond = Double(frameCount) / (now - lastFPSUpdate)
            frameCount = 0
            lastFPSUpdate = now
        }
    }
}
