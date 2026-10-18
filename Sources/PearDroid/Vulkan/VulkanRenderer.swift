import Foundation
import QuartzCore

/// A minimal Vulkan renderer that draws a single triangle into a `CAMetalLayer`
/// by way of MoltenVK (Vulkan ➜ Metal translation).
///
/// This is the graphics half of the PearDroid proof of concept: it shows that a
/// Vulkan swapchain can be presented into a native AppKit/SwiftUI surface on
/// Apple silicon — the same pipeline an Android game surface would later be
/// bridged onto.
///
/// Note on handles: on 64-bit platforms Vulkan defines *every* handle type
/// (dispatchable and non-dispatchable alike) as an opaque pointer, so in Swift
/// they all import as `OpaquePointer`. Creation entry points therefore take an
/// `UnsafeMutablePointer<VkFoo?>` out-parameter.
final class VulkanRenderer {

    static let maxFramesInFlight = 2

    private(set) var deviceName: String = "unknown"

    private let layer: CAMetalLayer

    // Core objects
    private var instance: VkInstance?
    private var surface: VkSurfaceKHR?
    private var physicalDevice: VkPhysicalDevice?
    private var device: VkDevice?
    private var graphicsQueue: VkQueue?
    private var queueFamily: UInt32 = 0

    // Swapchain
    private var swapchain: VkSwapchainKHR?
    private var swapchainFormat: VkFormat = VK_FORMAT_B8G8R8A8_UNORM
    private var swapchainExtent = VkExtent2D(width: 0, height: 0)
    private var requestedSize = (width: 0, height: 0)
    private var swapchainImages: [VkImage?] = []
    private var swapchainImageViews: [VkImageView?] = []
    private var framebuffers: [VkFramebuffer?] = []

    // Pipeline
    private var renderPass: VkRenderPass?
    private var pipelineLayout: VkPipelineLayout?
    private var graphicsPipeline: VkPipeline?

    // Commands & synchronisation
    private var commandPool: VkCommandPool?
    private var commandBuffers: [VkCommandBuffer?] = []
    private var imageAvailableSemaphores: [VkSemaphore?] = []
    private var renderFinishedSemaphores: [VkSemaphore?] = []
    private var inFlightFences: [VkFence?] = []
    private var frameIndex = 0

    // MARK: - Lifecycle

    init(layer: CAMetalLayer) throws {
        self.layer = layer

        requestedSize = (Int(layer.drawableSize.width), Int(layer.drawableSize.height))
        if requestedSize.width <= 0 || requestedSize.height <= 0 {
            requestedSize = (1280, 720)
        }

        try createInstance()
        try createSurface()
        try selectPhysicalDevice()
        try createLogicalDevice()

        try createCommandPool()
        try createSwapchain()
        try createRenderPass()
        try createGraphicsPipeline()
        try createSwapchainImageViews()
        try createFramebuffers()
        try createRenderFinishedSemaphores()
        try createCommandBuffers()
        try createSyncObjects()
    }

    deinit {
        teardown()
    }

    private func require<T>(_ value: T?, _ operation: String) throws -> T {
        guard let value else {
            throw VulkanError(operation: operation, result: VK_ERROR_INITIALIZATION_FAILED)
        }
        return value
    }

    // MARK: - Instance / device

    private func createInstance() throws {
        let extensions = ["VK_KHR_surface", "VK_EXT_metal_surface"]

        var created: VkInstance?
        let result: VkResult = "PearDroid".withCString { appName in
            "PearDroid PoC".withCString { engineName in
                var appInfo = VkApplicationInfo()
                appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
                appInfo.pApplicationName = appName
                appInfo.pEngineName = engineName
                appInfo.apiVersion = VulkanVersion.v1_2

                return withUnsafePointer(to: &appInfo) { appInfoPointer in
                    extensions.withCStringArray { names in
                        var createInfo = VkInstanceCreateInfo()
                        createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                        createInfo.pApplicationInfo = appInfoPointer
                        createInfo.enabledExtensionCount = UInt32(names.count)
                        createInfo.ppEnabledExtensionNames = names.baseAddress
                        return vkCreateInstance(&createInfo, nil, &created)
                    }
                }
            }
        }
        try vkCheck(result, "vkCreateInstance")
        instance = try require(created, "vkCreateInstance")
    }

    private func createSurface() throws {
        guard let instance else { return }

        var createInfo = VkMetalSurfaceCreateInfoEXT()
        createInfo.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT
        createInfo.pLayer = UnsafeRawPointer(Unmanaged.passUnretained(layer).toOpaque())

        var created: VkSurfaceKHR?
        try vkCheck(vkCreateMetalSurfaceEXT(instance, &createInfo, nil, &created),
                    "vkCreateMetalSurfaceEXT")
        surface = try require(created, "vkCreateMetalSurfaceEXT")
    }

    private func selectPhysicalDevice() throws {
        guard let instance, let surface else { return }

        var deviceCount: UInt32 = 0
        try vkCheck(vkEnumeratePhysicalDevices(instance, &deviceCount, nil),
                    "vkEnumeratePhysicalDevices")
        guard deviceCount > 0 else {
            throw VulkanError(operation: "no Vulkan physical device", result: VK_ERROR_INITIALIZATION_FAILED)
        }

        var devices = [VkPhysicalDevice?](repeating: nil, count: Int(deviceCount))
        try vkCheck(vkEnumeratePhysicalDevices(instance, &deviceCount, &devices),
                    "vkEnumeratePhysicalDevices")
        guard let device = devices.compactMap({ $0 }).first else {
            throw VulkanError(operation: "no Vulkan physical device", result: VK_ERROR_INITIALIZATION_FAILED)
        }
        physicalDevice = device

        var properties = VkPhysicalDeviceProperties()
        vkGetPhysicalDeviceProperties(device, &properties)
        deviceName = vkString(properties.deviceName)

        // Pick a queue family that can both render and present.
        var familyCount: UInt32 = 0
        vkGetPhysicalDeviceQueueFamilyProperties(device, &familyCount, nil)
        var families = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(), count: Int(familyCount))
        vkGetPhysicalDeviceQueueFamilyProperties(device, &familyCount, &families)

        var selected: UInt32?
        for index in 0..<Int(familyCount) {
            let family = families[index]
            guard family.queueCount > 0 else { continue }
            guard (family.queueFlags & VkQueueFlags(VK_QUEUE_GRAPHICS_BIT.rawValue)) != 0 else { continue }

            var presentSupported: VkBool32 = 0
            vkGetPhysicalDeviceSurfaceSupportKHR(device, UInt32(index), surface, &presentSupported)
            if presentSupported != 0 {
                selected = UInt32(index)
                break
            }
        }

        guard let family = selected else {
            throw VulkanError(operation: "no graphics+present queue family", result: VK_ERROR_INITIALIZATION_FAILED)
        }
        queueFamily = family
    }

    private func createLogicalDevice() throws {
        guard let physicalDevice else { return }

        var priority: Float = 1.0
        var queueInfo = VkDeviceQueueCreateInfo()
        queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
        queueInfo.queueFamilyIndex = queueFamily
        queueInfo.queueCount = 1

        var features = VkPhysicalDeviceFeatures()
        let extensions = ["VK_KHR_swapchain"]

        var created: VkDevice?
        let result: VkResult = withUnsafePointer(to: &priority) { priorityPointer in
            queueInfo.pQueuePriorities = priorityPointer
            return withUnsafePointer(to: &queueInfo) { queuePointer in
                withUnsafePointer(to: &features) { featuresPointer in
                    extensions.withCStringArray { names in
                        var createInfo = VkDeviceCreateInfo()
                        createInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                        createInfo.queueCreateInfoCount = 1
                        createInfo.pQueueCreateInfos = queuePointer
                        createInfo.pEnabledFeatures = featuresPointer
                        createInfo.enabledExtensionCount = UInt32(names.count)
                        createInfo.ppEnabledExtensionNames = names.baseAddress
                        return vkCreateDevice(physicalDevice, &createInfo, nil, &created)
                    }
                }
            }
        }
        try vkCheck(result, "vkCreateDevice")
        let deviceHandle = try require(created, "vkCreateDevice")
        device = deviceHandle

        var queue: VkQueue?
        vkGetDeviceQueue(deviceHandle, queueFamily, 0, &queue)
        graphicsQueue = queue
    }

    // MARK: - Swapchain

    private func surfaceCapabilities() throws -> VkSurfaceCapabilitiesKHR {
        guard let physicalDevice, let surface else {
            throw VulkanError(operation: "surfaceCapabilities", result: VK_ERROR_INITIALIZATION_FAILED)
        }
        var capabilities = VkSurfaceCapabilitiesKHR()
        try vkCheck(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice, surface, &capabilities),
                    "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")
        return capabilities
    }

    private func chooseSurfaceFormat() throws -> VkSurfaceFormatKHR {
        guard let physicalDevice, let surface else {
            throw VulkanError(operation: "chooseSurfaceFormat", result: VK_ERROR_INITIALIZATION_FAILED)
        }
        var count: UInt32 = 0
        try vkCheck(vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &count, nil),
                    "vkGetPhysicalDeviceSurfaceFormatsKHR")
        guard count > 0 else {
            throw VulkanError(operation: "no surface formats", result: VK_ERROR_INITIALIZATION_FAILED)
        }
        var formats = [VkSurfaceFormatKHR](repeating: VkSurfaceFormatKHR(), count: Int(count))
        try vkCheck(vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &count, &formats),
                    "vkGetPhysicalDeviceSurfaceFormatsKHR")

        if count == 1 && formats[0].format == VK_FORMAT_UNDEFINED {
            var format = VkSurfaceFormatKHR()
            format.format = VK_FORMAT_B8G8R8A8_UNORM
            format.colorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
            return format
        }
        for format in formats
        where format.format == VK_FORMAT_B8G8R8A8_UNORM
            && format.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR {
            return format
        }
        return formats[0]
    }

    private func createSwapchain() throws {
        guard let device, let surface else { return }

        let capabilities = try surfaceCapabilities()
        let format = try chooseSurfaceFormat()

        var extent = capabilities.currentExtent
        if extent.width == UInt32.max || extent.height == UInt32.max {
            extent = VkExtent2D(width: UInt32(max(requestedSize.width, 1)),
                                height: UInt32(max(requestedSize.height, 1)))
        }
        extent.width = min(max(extent.width, capabilities.minImageExtent.width),
                           capabilities.maxImageExtent.width)
        extent.height = min(max(extent.height, capabilities.minImageExtent.height),
                            capabilities.maxImageExtent.height)
        layer.drawableSize = CGSize(width: CGFloat(extent.width), height: CGFloat(extent.height))

        var imageCount = capabilities.minImageCount + 1
        if capabilities.maxImageCount > 0 && imageCount > capabilities.maxImageCount {
            imageCount = capabilities.maxImageCount
        }

        var createInfo = VkSwapchainCreateInfoKHR()
        createInfo.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
        createInfo.surface = surface
        createInfo.minImageCount = imageCount
        createInfo.imageFormat = format.format
        createInfo.imageColorSpace = format.colorSpace
        createInfo.imageExtent = extent
        createInfo.imageArrayLayers = 1
        createInfo.imageUsage = VkImageUsageFlags(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue)
        createInfo.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE
        createInfo.preTransform = capabilities.currentTransform
        createInfo.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
        createInfo.presentMode = VK_PRESENT_MODE_FIFO_KHR
        createInfo.clipped = VK_TRUE

        var created: VkSwapchainKHR?
        try vkCheck(vkCreateSwapchainKHR(device, &createInfo, nil, &created), "vkCreateSwapchainKHR")
        let swapchainHandle = try require(created, "vkCreateSwapchainKHR")
        swapchain = swapchainHandle
        swapchainFormat = format.format
        swapchainExtent = extent

        var actualCount: UInt32 = 0
        try vkCheck(vkGetSwapchainImagesKHR(device, swapchainHandle, &actualCount, nil),
                    "vkGetSwapchainImagesKHR")
        var images = [VkImage?](repeating: nil, count: Int(actualCount))
        try vkCheck(vkGetSwapchainImagesKHR(device, swapchainHandle, &actualCount, &images),
                    "vkGetSwapchainImagesKHR")
        swapchainImages = images
    }

    private func createSwapchainImageViews() throws {
        guard let device else { return }

        var views: [VkImageView?] = []
        views.reserveCapacity(swapchainImages.count)
        for image in swapchainImages {
            guard let image else { continue }
            var createInfo = VkImageViewCreateInfo()
            createInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
            createInfo.image = image
            createInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
            createInfo.format = swapchainFormat
            createInfo.components = VkComponentMapping(
                r: VK_COMPONENT_SWIZZLE_IDENTITY,
                g: VK_COMPONENT_SWIZZLE_IDENTITY,
                b: VK_COMPONENT_SWIZZLE_IDENTITY,
                a: VK_COMPONENT_SWIZZLE_IDENTITY)
            createInfo.subresourceRange = VkImageSubresourceRange(
                aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                baseMipLevel: 0,
                levelCount: 1,
                baseArrayLayer: 0,
                layerCount: 1)

            var view: VkImageView?
            try vkCheck(vkCreateImageView(device, &createInfo, nil, &view), "vkCreateImageView")
            views.append(view)
        }
        swapchainImageViews = views
    }

    private func createFramebuffers() throws {
        guard let device, let renderPass else { return }

        var buffers: [VkFramebuffer?] = []
        buffers.reserveCapacity(swapchainImageViews.count)
        for view in swapchainImageViews {
            guard let view else { continue }
            let attachments: [VkImageView?] = [view]
            var createInfo = VkFramebufferCreateInfo()
            createInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
            createInfo.renderPass = renderPass
            createInfo.attachmentCount = 1
            createInfo.width = swapchainExtent.width
            createInfo.height = swapchainExtent.height
            createInfo.layers = 1

            var framebuffer: VkFramebuffer?
            let result: VkResult = attachments.withUnsafeBufferPointer { pointer in
                createInfo.pAttachments = pointer.baseAddress
                return vkCreateFramebuffer(device, &createInfo, nil, &framebuffer)
            }
            try vkCheck(result, "vkCreateFramebuffer")
            buffers.append(framebuffer)
        }
        framebuffers = buffers
    }

    private func createRenderFinishedSemaphores() throws {
        guard let device else { return }

        var semaphores: [VkSemaphore?] = []
        semaphores.reserveCapacity(swapchainImages.count)
        for _ in swapchainImages {
            var createInfo = VkSemaphoreCreateInfo()
            createInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
            var semaphore: VkSemaphore?
            try vkCheck(vkCreateSemaphore(device, &createInfo, nil, &semaphore), "vkCreateSemaphore")
            semaphores.append(semaphore)
        }
        renderFinishedSemaphores = semaphores
    }

    private func createSyncObjects() throws {
        guard let device else { return }

        for _ in 0..<Self.maxFramesInFlight {
            var semaphoreInfo = VkSemaphoreCreateInfo()
            semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
            var imageSemaphore: VkSemaphore?
            try vkCheck(vkCreateSemaphore(device, &semaphoreInfo, nil, &imageSemaphore),
                        "vkCreateSemaphore")
            imageAvailableSemaphores.append(imageSemaphore)

            var fenceInfo = VkFenceCreateInfo()
            fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
            fenceInfo.flags = VkFenceCreateFlags(VK_FENCE_CREATE_SIGNALED_BIT.rawValue)
            var fence: VkFence?
            try vkCheck(vkCreateFence(device, &fenceInfo, nil, &fence), "vkCreateFence")
            inFlightFences.append(fence)
        }
    }

    // MARK: - Render pass & pipeline

    private func createRenderPass() throws {
        guard let device else { return }

        var colorAttachment = VkAttachmentDescription()
        colorAttachment.format = swapchainFormat
        colorAttachment.samples = VK_SAMPLE_COUNT_1_BIT
        colorAttachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
        colorAttachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE
        colorAttachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
        colorAttachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
        colorAttachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
        colorAttachment.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR

        var colorReference = VkAttachmentReference()
        colorReference.attachment = 0
        colorReference.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL

        var subpass = VkSubpassDescription()
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
        subpass.colorAttachmentCount = 1

        var dependency = VkSubpassDependency()
        dependency.srcSubpass = UInt32.max // VK_SUBPASS_EXTERNAL
        dependency.dstSubpass = 0
        dependency.srcStageMask = VkPipelineStageFlags(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
        dependency.dstStageMask = VkPipelineStageFlags(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
        dependency.srcAccessMask = 0
        dependency.dstAccessMask = VkAccessFlags(VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue)

        var created: VkRenderPass?
        let result: VkResult = withUnsafePointer(to: &colorReference) { referencePointer in
            subpass.pColorAttachments = referencePointer
            return withUnsafePointer(to: &colorAttachment) { attachmentPointer in
                withUnsafePointer(to: &subpass) { subpassPointer in
                    withUnsafePointer(to: &dependency) { dependencyPointer in
                        var createInfo = VkRenderPassCreateInfo()
                        createInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
                        createInfo.attachmentCount = 1
                        createInfo.pAttachments = attachmentPointer
                        createInfo.subpassCount = 1
                        createInfo.pSubpasses = subpassPointer
                        createInfo.dependencyCount = 1
                        createInfo.pDependencies = dependencyPointer
                        return vkCreateRenderPass(device, &createInfo, nil, &created)
                    }
                }
            }
        }
        try vkCheck(result, "vkCreateRenderPass")
        renderPass = try require(created, "vkCreateRenderPass")
    }

    private func createGraphicsPipeline() throws {
        guard let device, let renderPass else { return }

        let vertexWords = try Self.loadSPIRV("triangle.vert")
        let fragmentWords = try Self.loadSPIRV("triangle.frag")
        let vertexModule = try createShaderModule(words: vertexWords)
        let fragmentModule = try createShaderModule(words: fragmentWords)
        defer {
            vkDestroyShaderModule(device, vertexModule, nil)
            vkDestroyShaderModule(device, fragmentModule, nil)
        }

        var vertexStage = VkPipelineShaderStageCreateInfo()
        vertexStage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        vertexStage.stage = VK_SHADER_STAGE_VERTEX_BIT
        vertexStage.module = vertexModule

        var fragmentStage = VkPipelineShaderStageCreateInfo()
        fragmentStage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        fragmentStage.stage = VK_SHADER_STAGE_FRAGMENT_BIT
        fragmentStage.module = fragmentModule

        var vertexInput = VkPipelineVertexInputStateCreateInfo()
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO

        var inputAssembly = VkPipelineInputAssemblyStateCreateInfo()
        inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
        inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST

        var viewportState = VkPipelineViewportStateCreateInfo()
        viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
        viewportState.viewportCount = 1
        viewportState.scissorCount = 1

        var rasterization = VkPipelineRasterizationStateCreateInfo()
        rasterization.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
        rasterization.polygonMode = VK_POLYGON_MODE_FILL
        rasterization.cullMode = VkCullModeFlags(VK_CULL_MODE_NONE.rawValue)
        rasterization.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE
        rasterization.lineWidth = 1.0

        var multisample = VkPipelineMultisampleStateCreateInfo()
        multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT

        var colorBlendAttachment = VkPipelineColorBlendAttachmentState()
        colorBlendAttachment.blendEnable = VK_FALSE
        colorBlendAttachment.colorWriteMask = VkColorComponentFlags(
            VK_COLOR_COMPONENT_R_BIT.rawValue | VK_COLOR_COMPONENT_G_BIT.rawValue |
            VK_COLOR_COMPONENT_B_BIT.rawValue | VK_COLOR_COMPONENT_A_BIT.rawValue)

        var colorBlend = VkPipelineColorBlendStateCreateInfo()
        colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        colorBlend.attachmentCount = 1

        let dynamicStates: [VkDynamicState] = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
        var dynamicState = VkPipelineDynamicStateCreateInfo()
        dynamicState.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
        dynamicState.dynamicStateCount = UInt32(dynamicStates.count)

        var layoutInfo = VkPipelineLayoutCreateInfo()
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        var layout: VkPipelineLayout?
        try vkCheck(vkCreatePipelineLayout(device, &layoutInfo, nil, &layout), "vkCreatePipelineLayout")
        let layoutHandle = try require(layout, "vkCreatePipelineLayout")
        pipelineLayout = layoutHandle

        var stages = [vertexStage, fragmentStage]
        let colorBlendAttachments = [colorBlendAttachment]
        var pipelineCreateInfo = VkGraphicsPipelineCreateInfo()
        pipelineCreateInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
        pipelineCreateInfo.layout = layoutHandle
        pipelineCreateInfo.renderPass = renderPass
        pipelineCreateInfo.subpass = 0

        var created: VkPipeline?
        let result: VkResult = "main".withCString { namePointer in
            stages[0].pName = namePointer
            stages[1].pName = namePointer
            return stages.withUnsafeBufferPointer { stagesPointer in
                colorBlendAttachments.withUnsafeBufferPointer { attachmentPointer in
                    dynamicStates.withUnsafeBufferPointer { statesPointer in
                        colorBlend.pAttachments = attachmentPointer.baseAddress
                        colorBlend.attachmentCount = UInt32(attachmentPointer.count)
                        dynamicState.pDynamicStates = statesPointer.baseAddress
                        dynamicState.dynamicStateCount = UInt32(statesPointer.count)
                        return withUnsafePointer(to: &colorBlend) { colorBlendPointer in
                            withUnsafePointer(to: &dynamicState) { dynamicPointer in
                                withUnsafePointer(to: &vertexInput) { vertexInputPointer in
                                    withUnsafePointer(to: &inputAssembly) { inputAssemblyPointer in
                                        withUnsafePointer(to: &viewportState) { viewportPointer in
                                            withUnsafePointer(to: &rasterization) { rasterizationPointer in
                                                withUnsafePointer(to: &multisample) { multisamplePointer in
                                                    pipelineCreateInfo.stageCount = UInt32(stagesPointer.count)
                                                    pipelineCreateInfo.pStages = stagesPointer.baseAddress
                                                    pipelineCreateInfo.pVertexInputState = vertexInputPointer
                                                    pipelineCreateInfo.pInputAssemblyState = inputAssemblyPointer
                                                    pipelineCreateInfo.pViewportState = viewportPointer
                                                    pipelineCreateInfo.pRasterizationState = rasterizationPointer
                                                    pipelineCreateInfo.pMultisampleState = multisamplePointer
                                                    pipelineCreateInfo.pColorBlendState = colorBlendPointer
                                                    pipelineCreateInfo.pDynamicState = dynamicPointer
                                                    return vkCreateGraphicsPipelines(device, nil, 1, &pipelineCreateInfo, nil, &created)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        try vkCheck(result, "vkCreateGraphicsPipelines")
        graphicsPipeline = try require(created, "vkCreateGraphicsPipelines")
    }

    private func createShaderModule(words: [UInt32]) throws -> VkShaderModule {
        guard let device else {
            throw VulkanError(operation: "createShaderModule", result: VK_ERROR_INITIALIZATION_FAILED)
        }
        var createInfo = VkShaderModuleCreateInfo()
        createInfo.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
        createInfo.codeSize = words.count * MemoryLayout<UInt32>.size

        var module: VkShaderModule?
        let result: VkResult = words.withUnsafeBufferPointer { pointer in
            createInfo.pCode = pointer.baseAddress
            return vkCreateShaderModule(device, &createInfo, nil, &module)
        }
        try vkCheck(result, "vkCreateShaderModule")
        return try require(module, "vkCreateShaderModule")
    }

    private static func loadSPIRV(_ name: String) throws -> [UInt32] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "spv") else {
            throw VulkanError(operation: "missing shader \(name).spv", result: VK_ERROR_INITIALIZATION_FAILED)
        }
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count >= 4, bytes.count % 4 == 0 else {
            throw VulkanError(operation: "malformed shader \(name).spv", result: VK_ERROR_INITIALIZATION_FAILED)
        }
        var words = [UInt32](repeating: 0, count: bytes.count / 4)
        for index in words.indices {
            let offset = index * 4
            words[index] = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
        return words
    }

    // MARK: - Commands

    private func createCommandPool() throws {
        guard let device else { return }

        var createInfo = VkCommandPoolCreateInfo()
        createInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        createInfo.flags = VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
        createInfo.queueFamilyIndex = queueFamily

        var pool: VkCommandPool?
        try vkCheck(vkCreateCommandPool(device, &createInfo, nil, &pool), "vkCreateCommandPool")
        commandPool = try require(pool, "vkCreateCommandPool")
    }

    private func createCommandBuffers() throws {
        guard let device, let commandPool else { return }

        var allocateInfo = VkCommandBufferAllocateInfo()
        allocateInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocateInfo.commandPool = commandPool
        allocateInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocateInfo.commandBufferCount = UInt32(swapchainImages.count)

        var allocated = [VkCommandBuffer?](repeating: nil, count: swapchainImages.count)
        try vkCheck(vkAllocateCommandBuffers(device, &allocateInfo, &allocated),
                    "vkAllocateCommandBuffers")
        commandBuffers = allocated

        for index in commandBuffers.indices {
            guard let commandBuffer = commandBuffers[index] else { continue }
            try recordCommandBuffer(commandBuffer, imageIndex: index)
        }
    }

    private func recordCommandBuffer(_ commandBuffer: VkCommandBuffer, imageIndex: Int) throws {
        guard let renderPass, let graphicsPipeline, imageIndex < framebuffers.count else { return }

        var beginInfo = VkCommandBufferBeginInfo()
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        try vkCheck(vkBeginCommandBuffer(commandBuffer, &beginInfo), "vkBeginCommandBuffer")

        var clearValue = VkClearValue()
        clearValue.color = VkClearColorValue(float32: (0.06, 0.07, 0.09, 1.0))

        let renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: swapchainExtent)

        var beginRenderPass = VkRenderPassBeginInfo()
        beginRenderPass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
        beginRenderPass.renderPass = renderPass
        beginRenderPass.framebuffer = framebuffers[imageIndex]
        beginRenderPass.renderArea = renderArea
        beginRenderPass.clearValueCount = 1

        withUnsafePointer(to: &clearValue) { clearPointer in
            beginRenderPass.pClearValues = clearPointer
            vkCmdBeginRenderPass(commandBuffer, &beginRenderPass, VK_SUBPASS_CONTENTS_INLINE)
        }

        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, graphicsPipeline)

        var viewport = VkViewport(x: 0, y: 0,
                                  width: Float(swapchainExtent.width),
                                  height: Float(swapchainExtent.height),
                                  minDepth: 0, maxDepth: 1)
        vkCmdSetViewport(commandBuffer, 0, 1, &viewport)

        var scissor = renderArea
        vkCmdSetScissor(commandBuffer, 0, 1, &scissor)

        vkCmdDraw(commandBuffer, 3, 1, 0, 0)
        vkCmdEndRenderPass(commandBuffer)

        try vkCheck(vkEndCommandBuffer(commandBuffer), "vkEndCommandBuffer")
    }

    // MARK: - Frame loop

    func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard requestedSize.width != width || requestedSize.height != height || swapchain == nil else { return }
        requestedSize = (width, height)
        layer.drawableSize = CGSize(width: width, height: height)
        do {
            try recreateSwapchain()
        } catch {
            NSLog("PearDroid: swapchain recreation failed: \(error)")
        }
    }

    private func recreateSwapchain() throws {
        guard let device else { return }
        vkDeviceWaitIdle(device)
        destroySwapchainResources()
        try createSwapchain()
        try createSwapchainImageViews()
        try createFramebuffers()
        try createRenderFinishedSemaphores()
        try createCommandBuffers()
    }

    func drawFrame() throws {
        guard let device, let graphicsQueue, let swapchain else { return }

        vkWaitForFences(device, 1, &inFlightFences[frameIndex], VK_TRUE, UInt64.max)

        var imageIndex: UInt32 = 0
        let acquire = vkAcquireNextImageKHR(device, swapchain, UInt64.max,
                                            imageAvailableSemaphores[frameIndex], nil, &imageIndex)
        if acquire == VK_ERROR_OUT_OF_DATE_KHR {
            try recreateSwapchain()
            return
        }
        guard acquire == VK_SUCCESS || acquire == VK_SUBOPTIMAL_KHR else {
            throw VulkanError(operation: "vkAcquireNextImageKHR", result: acquire)
        }

        vkResetFences(device, 1, &inFlightFences[frameIndex])

        let waitSemaphores: [VkSemaphore?] = [imageAvailableSemaphores[frameIndex]]
        let signalSemaphores: [VkSemaphore?] = [renderFinishedSemaphores[Int(imageIndex)]]
        let waitStages = [VkPipelineStageFlags(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)]
        let buffers: [VkCommandBuffer?] = [commandBuffers[Int(imageIndex)]]

        var submitInfo = VkSubmitInfo()
        submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
        let submitResult: VkResult = waitSemaphores.withUnsafeBufferPointer { waitPointer in
            signalSemaphores.withUnsafeBufferPointer { signalPointer in
                waitStages.withUnsafeBufferPointer { stagePointer in
                    buffers.withUnsafeBufferPointer { bufferPointer in
                        submitInfo.waitSemaphoreCount = 1
                        submitInfo.pWaitSemaphores = waitPointer.baseAddress
                        submitInfo.pWaitDstStageMask = stagePointer.baseAddress
                        submitInfo.commandBufferCount = 1
                        submitInfo.pCommandBuffers = bufferPointer.baseAddress
                        submitInfo.signalSemaphoreCount = 1
                        submitInfo.pSignalSemaphores = signalPointer.baseAddress
                        return vkQueueSubmit(graphicsQueue, 1, &submitInfo, inFlightFences[frameIndex])
                    }
                }
            }
        }
        try vkCheck(submitResult, "vkQueueSubmit")

        let swapchains: [VkSwapchainKHR?] = [swapchain]
        let imageIndices = [imageIndex]
        var presentInfo = VkPresentInfoKHR()
        presentInfo.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
        let presentResult: VkResult = signalSemaphores.withUnsafeBufferPointer { signalPointer in
            swapchains.withUnsafeBufferPointer { swapchainPointer in
                imageIndices.withUnsafeBufferPointer { indexPointer in
                    presentInfo.waitSemaphoreCount = 1
                    presentInfo.pWaitSemaphores = signalPointer.baseAddress
                    presentInfo.swapchainCount = 1
                    presentInfo.pSwapchains = swapchainPointer.baseAddress
                    presentInfo.pImageIndices = indexPointer.baseAddress
                    return vkQueuePresentKHR(graphicsQueue, &presentInfo)
                }
            }
        }
        if presentResult == VK_ERROR_OUT_OF_DATE_KHR || presentResult == VK_SUBOPTIMAL_KHR {
            try recreateSwapchain()
        } else {
            try vkCheck(presentResult, "vkQueuePresentKHR")
        }

        frameIndex = (frameIndex + 1) % Self.maxFramesInFlight
    }

    // MARK: - Teardown

    private func destroySwapchainResources() {
        guard let device else { return }

        for framebuffer in framebuffers {
            if let framebuffer { vkDestroyFramebuffer(device, framebuffer, nil) }
        }
        framebuffers.removeAll()

        for view in swapchainImageViews {
            if let view { vkDestroyImageView(device, view, nil) }
        }
        swapchainImageViews.removeAll()

        for semaphore in renderFinishedSemaphores {
            if let semaphore { vkDestroySemaphore(device, semaphore, nil) }
        }
        renderFinishedSemaphores.removeAll()

        if let commandPool, !commandBuffers.isEmpty {
            let count = UInt32(commandBuffers.count)
            commandBuffers.withUnsafeBufferPointer { pointer in
                vkFreeCommandBuffers(device, commandPool, count, pointer.baseAddress)
            }
            commandBuffers.removeAll()
        }

        if let swapchain {
            vkDestroySwapchainKHR(device, swapchain, nil)
        }
        swapchain = nil
        swapchainImages.removeAll()
    }

    private func teardown() {
        guard let device else { return }
        vkDeviceWaitIdle(device)

        for fence in inFlightFences { if let fence { vkDestroyFence(device, fence, nil) } }
        inFlightFences.removeAll()
        for semaphore in imageAvailableSemaphores { if let semaphore { vkDestroySemaphore(device, semaphore, nil) } }
        imageAvailableSemaphores.removeAll()

        destroySwapchainResources()

        if let commandPool { vkDestroyCommandPool(device, commandPool, nil) }
        commandPool = nil
        if let graphicsPipeline { vkDestroyPipeline(device, graphicsPipeline, nil) }
        graphicsPipeline = nil
        if let pipelineLayout { vkDestroyPipelineLayout(device, pipelineLayout, nil) }
        pipelineLayout = nil
        if let renderPass { vkDestroyRenderPass(device, renderPass, nil) }
        renderPass = nil

        vkDestroyDevice(device, nil)
        self.device = nil

        if let surface, let instance { vkDestroySurfaceKHR(instance, surface, nil) }
        surface = nil
        if let instance { vkDestroyInstance(instance, nil) }
        self.instance = nil
    }
}
