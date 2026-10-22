import Foundation

#if !NO_LLAMA_ENGINE

/// llama.cpp bindings. CPU backend by default (this repo links the CPU/Accelerate
/// build of ggml — see Scripts/build_llama.sh), Metal optional.
///
/// Lifetime: one model + one context per app process. Loading mmaps the GGUF, so
/// resident memory tracks the pages actually touched instead of the file size.
/// Generation runs on a dedicated queue; the Swift API is an AsyncThrowingStream so
/// the UI renders tokens as they arrive.
public final class LlamaEngine: LLMEngine {

    public let name = "llama.cpp (GGUF)"
    public private(set) var stats = GenerationStats()

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var config: EngineConfig?

    private let stateLock = NSLock()
    private let decodeQueue = DispatchQueue(label: "llama.decode", qos: .userInitiated)
    private var cancelFlag = false

    public init() {}

    deinit { unload() }

    public var isReady: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return model != nil && ctx != nil && vocab != nil
    }

    // MARK: - Lifecycle

    public func load(config: EngineConfig) throws {
        unload()

        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            throw EngineError.modelMissing(config.modelPath)
        }

        llama_backend_init()

        let loadStart = Date()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Int32(config.gpuLayers)
        modelParams.load_mode = config.useMmap ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE
        modelParams.check_tensors = false
        modelParams.use_extra_bufts = false

        guard let loadedModel = llama_model_load_from_file(config.modelPath, modelParams) else {
            throw EngineError.modelLoadFailed("llama_model_load_from_file returned NULL for \(URL(fileURLWithPath: config.modelPath).lastPathComponent)")
        }

        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_model_free(loadedModel)
            throw EngineError.modelLoadFailed("model has no vocabulary")
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(config.contextLength)
        contextParams.n_batch = UInt32(config.batchSize)
        contextParams.n_ubatch = UInt32(min(config.batchSize, 256))
        contextParams.n_threads = Int32(max(1, config.threads))
        contextParams.n_threads_batch = Int32(max(1, config.threads))
        contextParams.no_perf = true

        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw EngineError.contextCreateFailed
        }

        stateLock.lock()
        self.model = loadedModel
        self.vocab = loadedVocab
        self.ctx = loadedContext
        self.config = config
        var s = GenerationStats()
        s.contextSize = config.contextLength
        s.loadSeconds = Date().timeIntervalSince(loadStart)
        self.stats = s
        stateLock.unlock()

        AppLog.info("model loaded in \(String(format: "%.2f", s.loadSeconds))s, ctx=\(config.contextLength), threads=\(config.threads), gpu_layers=\(config.gpuLayers)")
    }

    public func unload() {
        stateLock.lock()
        let context = ctx
        let model = self.model
        ctx = nil
        vocab = nil
        self.model = nil
        config = nil
        stateLock.unlock()

        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        llama_backend_free()
    }

    public func cancel() {
        stateLock.lock()
        cancelFlag = true
        stateLock.unlock()
    }

    private var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelFlag
    }

    // MARK: - Generation

    public func stream(turns: [ChatTurn], sampling: SamplingConfig) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            decodeQueue.async { [weak self] in
                guard let self else { continuation.finish(); return }
                self.stateLock.lock()
                self.cancelFlag = false
                self.stateLock.unlock()
                do {
                    try self.generate(turns: turns, sampling: sampling, continuation: continuation)
                    continuation.finish()
                } catch let error as EngineError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func generate(turns: [ChatTurn],
                          sampling: SamplingConfig,
                          continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation) throws {
        stateLock.lock()
        let context = ctx
        let vocab = self.vocab
        let cfg = config
        stateLock.unlock()

        guard let context, let vocab, let cfg else { throw EngineError.modelLoadFailed("engine not loaded") }

        let started = Date()
        let prompt = renderPrompt(turns: turns, model: model)
        let promptTokens = tokenize(prompt, vocab: vocab, addSpecial: true)
        guard !promptTokens.isEmpty else { throw EngineError.tokenizationFailed }

        let contextLimit = cfg.contextLength - 8
        var inputTokens = promptTokens
        if inputTokens.count > contextLimit {
            // Keep the head (system + instructions) and the tail (question + sources
            // closest to the question), drop the middle.
            let head = Array(inputTokens.prefix(contextLimit / 3))
            let tail = Array(inputTokens.suffix(contextLimit - head.count))
            inputTokens = head + tail
            AppLog.warn("prompt truncated from \(promptTokens.count) to \(inputTokens.count) tokens")
        }

        llama_memory_clear(llama_get_memory(context), true)

        // Prefill in n_batch-sized chunks.
        let batchSize = max(1, Int(cfg.batchSize))
        var offset = 0
        while offset < inputTokens.count {
            let slice = Array(inputTokens[offset ..< min(offset + batchSize, inputTokens.count)])
            var mutable = slice
            let rc = mutable.withUnsafeMutableBufferPointer { buffer -> Int32 in
                let batch = llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))
                return llama_decode(context, batch)
            }
            if rc != 0 { throw EngineError.decodeFailed(rc) }
            offset += slice.count
            if isCancelled { throw EngineError.cancelled }
        }

        guard let sampler = makeSampler(sampling) else { throw EngineError.modelLoadFailed("sampler chain") }
        defer { llama_sampler_free(sampler) }

        var decoder = UTF8StreamDecoder()
        var output = ""
        var generated = 0
        var firstTokenAt: TimeInterval = 0
        var stopReason = "max_tokens"
        var consumed = inputTokens.count

        while generated < sampling.maxTokens {
            if isCancelled {
                continuation.yield(.token(""))
                throw EngineError.cancelled
            }
            if consumed >= cfg.contextLength - 2 {
                stopReason = "context_full"
                break
            }

            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                stopReason = "eog"
                break
            }

            let piece = tokenToPiece(token, vocab: vocab)
            if !piece.isEmpty {
                let text = decoder.feed(piece)
                if !text.isEmpty {
                    if firstTokenAt == 0 { firstTokenAt = Date().timeIntervalSince(started) }
                    output += text
                    continuation.yield(.token(text))

                    if let hit = stopSequenceHit(in: output, stops: sampling.stopSequences) {
                        output = hit
                        stopReason = "stop_sequence"
                        break
                    }
                }
            }

            var next = [token]
            let rc = next.withUnsafeMutableBufferPointer { buffer -> Int32 in
                let batch = llama_batch_get_one(buffer.baseAddress, 1)
                return llama_decode(context, batch)
            }
            if rc != 0 { throw EngineError.decodeFailed(rc) }
            generated += 1
            consumed += 1
        }

        let trailing = decoder.flush()
        if !trailing.isEmpty {
            output += trailing
            continuation.yield(.token(trailing))
        }

        var final = GenerationStats()
        final.promptTokens = inputTokens.count
        final.generatedTokens = generated
        final.firstTokenSeconds = firstTokenAt
        final.contextUsed = consumed
        final.contextSize = cfg.contextLength
        final.loadSeconds = stats.loadSeconds
        let elapsed = Date().timeIntervalSince(started) - firstTokenAt
        final.tokensPerSecond = (generated > 0 && elapsed > 0) ? Double(generated) / elapsed : 0

        stateLock.lock()
        stats = final
        stateLock.unlock()

        AppLog.info("generated \(generated) tokens at \(String(format: "%.1f", final.tokensPerSecond)) tok/s (\(stopReason))")
        continuation.yield(.stats(final))
    }

    // MARK: - Helpers

    private func renderPrompt(turns: [ChatTurn], model: OpaquePointer?) -> String {
        // Prefer the template baked into the GGUF (llama.cpp's built-in template table).
        var roles: [UnsafeMutablePointer<CChar>?] = turns.map { strdup($0.role.rawValue) }
        var contents: [UnsafeMutablePointer<CChar>?] = turns.map { strdup($0.content) }
        defer {
            roles.forEach { if let r = $0 { free(r) } }
            contents.forEach { if let c = $0 { free(c) } }
        }

        var messages: [llama_chat_message] = []
        for i in 0..<turns.count {
            guard let role = roles[i], let content = contents[i] else { continue }
            messages.append(llama_chat_message(role: UnsafePointer(role), content: UnsafePointer(content)))
        }

        if !messages.isEmpty {
            let needed = llama_chat_apply_template(nil, &messages, messages.count, true, nil, 0)
            if needed > 0 {
                var buffer = [CChar](repeating: 0, count: Int(needed) + 16)
                let written = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                    llama_chat_apply_template(nil, &messages, messages.count, true, buf.baseAddress, Int32(buf.count))
                }
                if written > 0, let text = String(validatingUTF8: buffer) {
                    return text
                }
            }
        }

        // Fallback: ChatML, which is what the shipped Qwen2.5 / SmolLM2 GGUFs use.
        var out = ""
        for turn in turns {
            out += "<|im_start|>\(turn.role.rawValue)\n\(turn.content)<|im_end|>\n"
        }
        out += "<|im_start|>assistant\n"
        return out
    }

    private func tokenize(_ text: String, vocab: OpaquePointer, addSpecial: Bool) -> [llama_token] {
        let utf8Count = text.utf8.count
        var capacity = max(32, utf8Count + 8)
        for _ in 0..<3 {
            var tokens = [llama_token](repeating: 0, count: capacity)
            let count = tokens.withUnsafeMutableBufferPointer { buffer -> Int32 in
                llama_tokenize(vocab, text, Int32(utf8Count), buffer.baseAddress, Int32(buffer.count), addSpecial, true)
            }
            if count >= 0 {
                return Array(tokens.prefix(Int(count)))
            }
            // Negative return = required capacity.
            capacity = max(capacity * 2, Int(-count) + 8)
        }
        return []
    }

    private func tokenToPiece(_ token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
            llama_token_to_piece(vocab, token, buf.baseAddress, Int32(buf.count), 0, false)
        }
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    }

    private func makeSampler(_ sampling: SamplingConfig) -> OpaquePointer? {
        let params = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(params) else { return nil }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(sampling.topK)))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(sampling.topP), 1))
        llama_sampler_chain_add(chain, llama_sampler_init_min_p(Float(sampling.minP), 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(max(0.01, sampling.temperature))))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(sampling.seed))
        return chain
    }

    private func stopSequenceHit(in text: String, stops: [String]) -> String? {
        for stop in stops where !stop.isEmpty {
            if let range = text.range(of: stop) {
                return String(text[..<range.lowerBound])
            }
        }
        return nil
    }
}

#endif
