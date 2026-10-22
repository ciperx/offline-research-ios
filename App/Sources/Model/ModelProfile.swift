import Foundation

/// A downloadable GGUF profile. Mirrors `App/Resources/models.json` (same file the
/// shell script reads), so the app and the build tooling can never disagree about a
/// checksum.
public struct ModelProfile: Codable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let family: String
    public let parameters: String
    public let quantization: String
    public let file: String
    public let url: String
    public let sizeBytes: Int64
    public let sha256: String
    public let contextTrain: Int
    public let recommendedContext: Int
    public let ramEstimateMB: Int
    public let chatTemplate: String
    public let license: String
    public let licenseURL: String
    public let notes: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case family
        case parameters
        case quantization
        case file
        case url
        case sizeBytes = "size_bytes"
        case sha256
        case contextTrain = "context_train"
        case recommendedContext = "recommended_context"
        case ramEstimateMB = "ram_estimate_mb"
        case chatTemplate = "chat_template"
        case license
        case licenseURL = "license_url"
        case notes
    }

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public var shortLabel: String {
        "\(parameters) · \(quantization)"
    }

    /// KV-cache + compute overhead on top of the mmap'd weights, in MB.
    /// Rough but useful: GQA models with 2 KV heads cost ~64 KB per token per layer
    /// at f16, so a 4096-token context adds a few hundred MB, not gigabytes.
    public func estimatedResidentMB(contextLength: Int) -> Int {
        let weightMB = Int(Double(sizeBytes) / 1_048_576.0)
        let kvMB = Int(Double(contextLength) * 0.055)
        return weightMB + kvMB + 220
    }
}

public struct ModelCatalog: Codable {
    public let schema: Int
    public let updated: String
    public let defaultModel: String
    public let note: String
    public let models: [ModelProfile]

    enum CodingKeys: String, CodingKey {
        case schema, updated, note, models
        case defaultModel = "default_model"
    }
}

public enum ModelRegistryError: LocalizedError {
    case catalogMissing(String)
    case catalogInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .catalogMissing(let name): return "Bundled model catalog \(name) is missing"
        case .catalogInvalid(let detail): return "Model catalog is invalid: \(detail)"
        }
    }
}

/// Loads the bundled catalog and picks a sensible profile for the device.
public final class ModelRegistry {
    public let catalog: ModelCatalog

    public init(bundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw ModelRegistryError.catalogMissing(bundleURL.lastPathComponent)
        }
        do {
            let data = try Data(contentsOf: bundleURL)
            let decoder = JSONDecoder()
            self.catalog = try decoder.decode(ModelCatalog.self, from: data)
        } catch {
            throw ModelRegistryError.catalogInvalid(String(describing: error))
        }
    }

    public var all: [ModelProfile] { catalog.models }

    public var defaultProfile: ModelProfile? {
        catalog.models.first { $0.id == catalog.defaultModel } ?? catalog.models.first
    }

    public func profile(id: String) -> ModelProfile? {
        catalog.models.first { $0.id == id }
    }

    public func profile(fileName: String) -> ModelProfile? {
        catalog.models.first { $0.file == fileName }
    }

    /// Largest profile whose estimated resident memory fits in 55% of physical RAM.
    /// The remaining headroom is for the app, the index and the OS.
    public func recommended(forPhysicalMemory bytes: UInt64) -> ModelProfile? {
        let budgetMB = Int(Double(bytes) / 1_048_576.0 * 0.55)
        let fitting = catalog.models
            .filter { $0.estimatedResidentMB(contextLength: $0.recommendedContext) <= budgetMB }
            .sorted { $0.sizeBytes > $1.sizeBytes }
        return fitting.first ?? catalog.models.min { $0.sizeBytes < $1.sizeBytes }
    }
}
