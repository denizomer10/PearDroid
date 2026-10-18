import Foundation

/// Metadata about an installed APK, as read directly from its manifest.
struct ApkInfo: Identifiable, Hashable {
    let url: URL
    let fileName: String
    let sizeBytes: Int64
    let packageName: String?
    let label: String?
    let versionName: String?
    let versionCode: Int?

    var id: URL { url }

    var displayName: String { label ?? packageName ?? fileName }

    var packageId: String { packageName ?? "unknown.package" }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Finds `.apk` files in a directory and reads their manifests.
enum ApkScanner {
    /// Directory users drop APKs into: `~/Library/Application Support/PearDroid/apks`.
    static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PearDroid/apks", isDirectory: true)
    }

    @discardableResult
    static func ensureDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    static func scan(directory: URL) -> [ApkInfo] {
        ensureDirectory(directory)
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: keys,
                                                                     options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "apk" }
            .compactMap { inspect($0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func inspect(_ url: URL) -> ApkInfo? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        var manifest: AndroidBinaryXML.Manifest?
        var label: String?

        if let zip = try? ZipReader(url: url), let entries = try? zip.entries() {
            if let manifestEntry = entries.first(where: { $0.name == "AndroidManifest.xml" }),
               let manifestData = try? zip.data(for: manifestEntry) {
                manifest = AndroidBinaryXML.parseManifest(manifestData)
            }
            label = manifest?.label
            if label == nil,
               let resourceId = manifest?.labelResourceId,
               let arscEntry = entries.first(where: { $0.name == "resources.arsc" }),
               let arscData = try? zip.data(for: arscEntry) {
                label = AndroidResources.resolveString(in: arscData, resourceId: resourceId)
            }
        }

        return ApkInfo(url: url,
                       fileName: url.lastPathComponent,
                       sizeBytes: size,
                       packageName: manifest?.packageName,
                       label: label,
                       versionName: manifest?.versionName,
                       versionCode: manifest?.versionCode)
    }
}
