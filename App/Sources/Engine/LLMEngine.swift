import Foundation

/// One chat turn, engine-agnostic. The prompt builder produces these; each engine
/// decides how to render them (chat template for llama.cpp, plain text for the
/// extractive engine).
public struct ChatTurn: Equatable, Identifiable {
    public enum Role: String, Equatable {
        case system
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public let content: String

    public init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    public init(role: Role, content: String) {
        self.init(id: UUID(), role: role, content: content)
    }
}

public struct SamplingConfig: Equatable {
    public var temperature: Double = 0.6
    public var topK: Int = 40
    public var topP: Double = 0.92
    public var minP: Double = 0.05
    public var maxTokens: Int = 512
    public var seed: UInt32 = 0x5EED_1405
    /// Generation stops when any of these strings appears in the output tail.
    public var stopSequences: [String] = ["<|im_end|>", "<|endoftext|>", "\nUser:", "\nQuestion:"]

    public init() {}
}

public struct EngineConfig: Equatable {
    public var modelPath: String
    public var contextLength: Int = 4096
    public var batchSize: Int = 512
    public var threads: Int = 4
    /// 0 = CPU only (default on iOS builds of this repo: no Metal backend is linked).
    public var gpuLayers: Int = 0
    public var useMmap: Bool = true

    public init(modelPath: String) {
        self.modelPath = modelPath
    }
}

public struct GenerationStats: Equatable {
    public var promptTokens: Int = 0
    public var generatedTokens: Int = 0
    public var tokensPerSecond: Double = 0
    public var loadSeconds: Double = 0
    public var firstTokenSeconds: Double = 0
    public var contextUsed: Int = 0
    public var contextSize: Int = 0
}

public enum EngineEvent {
    case token(String)
    case stats(GenerationStats)
}

public enum EngineError: LocalizedError, Equatable {
    case modelMissing(String)
    case modelLoadFailed(String)
    case contextCreateFailed
    case tokenizationFailed
    case decodeFailed(Int32)
    case contextOverflow(limit: Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let path): return "No model file at \(path)"
        case .modelLoadFailed(let detail): return "Model failed to load: \(detail)"
        case .contextCreateFailed: return "Could not create a llama.cpp context (out of memory?)"
        case .tokenizationFailed: return "Tokenizer rejected the prompt"
        case .decodeFailed(let code): return "llama_decode failed with code \(code)"
        case .contextOverflow(let limit): return "Prompt + answer exceeds the \(limit)-token context"
        case .cancelled: return "Generation cancelled"
        }
    }
}

/// The app talks to this, never to llama.cpp directly. Two implementations ship:
/// `LlamaEngine` (GGUF on device) and `ExtractiveEngine` (retrieval only, no model).
public protocol LLMEngine: AnyObject {
    var name: String { get }
    var isReady: Bool { get }
    var stats: GenerationStats { get }

    func load(config: EngineConfig) throws
    func stream(turns: [ChatTurn], sampling: SamplingConfig) -> AsyncThrowingStream<EngineEvent, Error>
    func cancel()
    func unload()
}
