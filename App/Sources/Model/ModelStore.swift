import Foundation

/// Disk-side model management: where GGUFs live, how they get there, what happens
/// when one fails its checksum.
///
/// Layout (Application Support, backed up=False so a 1.1 GB blob never enters an
/// iCloud backup):
///
///     Application Support/Models/<profile file>.gguf
///
/// Models are installed three ways, all of them user-visible:
///   1. `make model` on the Mac + "Add model file…" in the app (Files/document picker);
///   2. drag-and-drop into the app's Documents folder over Finder/iTunes file sharing
///      (UIFileSharingEnabled is on);
///   3. never. Models are not downloaded by the app — the app has no network code.
public final class ModelStore {

    public enum StoreError: LocalizedError {
        case checksumMismatch(expected: String, actual: String)
        case insufficientSpace(neededBytes: Int64, availableBytes: Int64)
        case copyFailed(String)
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .checksumMismatch(let expected, let actual):
                return "Checksum mismatch. Expected \(expected.prefix(12))…, got \(actual.prefix(12))…"
            case .insufficientSpace(let needed, let available):
                return "Not enough free space: need \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), have \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))"
            case .copyFailed(let detail): return "Copy failed: \(detail)"
            case .notFound(let name): return "Model \(name) is not installed"
            }
        }
    }

    public struct InstalledModel: Equatable, Identifiable {
        public let fileName: String
        public let url: URL
        public let sizeBytes: Int64
        public let modified: Date
        public var id: String { fileName }
        public var displayName: String { fileName.replacingOccurrences(of: ".gguf", with: "") }
    }

    private let fileManager: FileManager
    public let directory: URL

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = base.appendingPathComponent("Models", isDirectory: true)
    }

    public var directoryExists: Bool {
        fileManager.fileExists(atPath: directory.path)
    }

    public func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    public func installed() -> [InstalledModel] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return InstalledModel(
                    fileName: url.lastPathComponent,
                    url: url,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.displayName < $1.displayName }
    }

    public func locate(profile: ModelProfile) -> URL? {
        let url = directory.appendingPathComponent(profile.file)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func locate(fileName: String) -> URL? {
        let url = directory.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Copy a user-picked file into the models directory.
    ///
    /// - Parameters:
    ///   - source: a security-scoped URL from `fileImporter` (or a Documents path).
    ///   - profile: catalog entry to validate against; `nil` accepts any GGUF.
    ///   - verifyChecksum: skip only when the user explicitly opts out (large files
    ///     on an old device still hash at ~200 MB/s, so the default is to verify).
    public func install(from source: URL, profile: ModelProfile?, verifyChecksum: Bool = true) throws -> InstalledModel {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let free = freeSpaceBytes()
        if size > 0 && free < size + 100_000_000 {
            throw StoreError.insufficientSpace(neededBytes: size, availableBytes: free)
        }

        try ensureDirectory()
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }

        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw StoreError.copyFailed(String(describing: error))
        }

        if verifyChecksum, let profile {
            let actual = try SHA256.hexOfFile(at: destination)
            guard actual.caseInsensitiveCompare(profile.sha256) == .orderedSame else {
                try? fileManager.removeItem(at: destination)
                throw StoreError.checksumMismatch(expected: profile.sha256, actual: actual)
            }
        }

        let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return InstalledModel(
            fileName: destination.lastPathComponent,
            url: destination,
            sizeBytes: Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate ?? Date()
        )
    }

    public func remove(_ model: InstalledModel) throws {
        guard fileManager.fileExists(atPath: model.url.path) else {
            throw StoreError.notFound(model.fileName)
        }
        try fileManager.removeItem(at: model.url)
    }

    public func freeSpaceBytes() -> Int64 {
        let values = try? directory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        return Int64(0)
    }

    public static var physicalMemoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Where the app's Documents folder lives, so the README/settings can tell the
    /// user exactly where to drop a GGUF over Finder.
    public func documentsPath() -> String {
        (fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())).path
    }
}
