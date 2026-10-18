import Foundation

// MARK: - Vulkan version helpers
//
// The VK_MAKE_VERSION / VK_API_VERSION_* macros are not visible to Swift, so we
// reproduce the packing here.
@inline(__always)
func vkMakeVersion(major: UInt32, minor: UInt32, patch: UInt32) -> UInt32 {
    (major << 29) | (minor << 22) | (patch << 12)
}

enum VulkanVersion {
    /// Vulkan 1.2 — comfortably within what MoltenVK exposes.
    static let v1_2 = vkMakeVersion(major: 1, minor: 2, patch: 0)
}

// MARK: - Result handling

struct VulkanError: Error, CustomStringConvertible {
    let operation: String
    let result: VkResult

    var description: String {
        "\(operation) failed (VkResult = \(result.rawValue))"
    }
}

@discardableResult
@inline(__always)
func vkCheck(_ result: VkResult, _ operation: String) throws -> VkResult {
    guard result == VK_SUCCESS else {
        throw VulkanError(operation: operation, result: result)
    }
    return result
}

// MARK: - C string helpers

/// Reads a NUL-terminated C string held in a fixed-size tuple, e.g. Vulkan's
/// `char name[VK_MAX_*_NAME_SIZE]` fields.
@inline(__always)
func vkString<T>(_ value: T) -> String {
    var copy = value
    return withUnsafePointer(to: &copy) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
}

extension Array where Element == String {
    /// Runs `body` with a NULL-terminated array of C strings, keeping the
    /// underlying buffers alive for the duration of the call.
    func withCStringArray<R>(_ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) throws -> R) rethrows -> R {
        let cStrings: [UnsafeMutablePointer<CChar>] = compactMap { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        return try pointers.withUnsafeBufferPointer { try body($0) }
    }
}
