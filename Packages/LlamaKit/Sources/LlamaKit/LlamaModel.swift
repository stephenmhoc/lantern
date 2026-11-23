import Foundation
import os
import llama

public struct ChatMessage: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant }
    public var role: Role
    public var content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct Sampling: Sendable {
    public var temperature: Float
    public var topK: Int32  // 0 = off
    public var topP: Float  // 1 = off
    public init(temperature: Float, topK: Int32 = 0, topP: Float = 1) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
    }
}

public struct GenerationStats: Sendable {
    public var promptTokens = 0
    public var reusedTokens = 0
    public var generatedTokens = 0
    public var promptSeconds = 0.0
    public var generateSeconds = 0.0
    public init() {}
    public var tokensPerSecond: Double { generateSeconds > 0 ? Double(generatedTokens) / generateSeconds : 0 }
}

public enum Generation: Sendable {
    /// Share of the prompt processed so far; sent between chunks of a long prompt.
    case reading(Double)
    case thinking(String)
    case text(String)
    case done(GenerationStats)
}

public enum LlamaError: Error, LocalizedError {
    case loadFailed(String)
    case unsupportedModel
    case contextFailed
    case tokenizeFailed
    case contextFull
    case processFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let path): "Couldn't load the model at \(path)."
        case .unsupportedModel: "Lantern doesn't know this model's chat format."
        case .contextFailed: "Couldn't create a context. The device may be out of memory."
        case .tokenizeFailed: "Couldn't tokenize the prompt."
        case .contextFull: "This chat is too long for the model. Start a new chat."
        case .processFailed(let code): "The model stopped with error \(code)."
        }
    }
}

/// One loaded GGUF and its context. Every llama call happens on `queue`, so the C pointers are
/// never touched from two threads at once; that's what makes the `@unchecked Sendable` sound.
/// To stop a generation, stop iterating its stream (cancel the task reading it).
public final class LlamaModel: @unchecked Sendable {
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let template: ChatTemplate
    private let queue = DispatchQueue(label: "LlamaModel", qos: .userInitiated)
    /// Tokens currently in the KV cache.
    private var cached: [llama_token] = []
    /// The conversation the cache holds, ending with a reply the model closed with its own turn-end
    /// token. When the next call extends it, only the new turns are processed.
    private var transcript: (messages: [ChatMessage], thinking: Thinking)?

    public let contextLength: Int
    public var sizeBytes: UInt64 { llama_model_size(model) }
    public var templateName: String { template.format.rawValue }

    private static let backend: Void = llama_backend_init()
    private static let batchSize = 512
    /// Room kept free for the reply; a prompt that leaves less is treated as too long.
    private static let replyRoom = 1024

    /// Loads synchronously; call from a background task. `lazyExperts` reads MoE expert rows from
    /// storage as they're used, which is what lets a model bigger than the app's memory limit run.
    public init(
        path: String, lazyExperts: Bool = false, contextLength: UInt32 = 8192,
        progress: (@Sendable (Float) -> Void)? = nil
    ) throws {
        _ = Self.backend
        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        mp.load_mode = LLAMA_LOAD_MODE_MMAP
        mp.lazy_mode = lazyExperts ? LLAMA_LAZY_MODE_ON : LLAMA_LAZY_MODE_OFF
        let box = progress.map { Unmanaged.passRetained(ProgressBox($0)) }
        defer { box?.release() }
        if let box {
            mp.progress_callback = { value, data in
                Unmanaged<ProgressBox>.fromOpaque(data!).takeUnretainedValue().callback(value)
                return true
            }
            mp.progress_callback_user_data = box.toOpaque()
        }
        #if targetEnvironment(simulator)
        // The simulator's Metal driver aborts on llama.cpp's host-memory buffers: CPU only there.
        var devices: [ggml_backend_dev_t?] = [ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU), nil]
        mp.n_gpu_layers = 0
        let loaded = devices.withUnsafeMutableBufferPointer { buf in
            mp.devices = buf.baseAddress
            return llama_model_load_from_file(path, mp)
        }
        #else
        let loaded = llama_model_load_from_file(path, mp)
        #endif
        guard let model = loaded else { throw LlamaError.loadFailed(path) }
        guard let template = ChatTemplate(model: model) else {
            llama_model_free(model)
            throw LlamaError.unsupportedModel
        }

        var cp = llama_context_default_params()
        cp.n_ctx = contextLength
        cp.n_batch = UInt32(Self.batchSize)
        cp.n_ubatch = UInt32(Self.batchSize)
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        cp.type_k = GGML_TYPE_Q8_0  // half the memory of f16 for a small quality cost
        cp.type_v = GGML_TYPE_Q8_0
        let threads = Int32(max(1, min(ProcessInfo.processInfo.activeProcessorCount - 2, 6)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        #if targetEnvironment(simulator)
        cp.offload_kqv = false
        cp.op_offload = false
        #endif
        guard let ctx = llama_init_from_model(model, cp) else {
            llama_model_free(model)
            throw LlamaError.contextFailed
        }
        self.model = model
        self.ctx = ctx
        self.vocab = llama_model_get_vocab(model)
        self.contextLength = Int(llama_n_ctx(ctx))
        self.template = template
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    /// Streams the reply. Generations queue behind each other; each has its own stop flag, set when
    /// the reader stops iterating, so stopping one can never stop the next.
    public func generate(
        _ messages: [ChatMessage], sampling: Sampling, thinking: Thinking = .off, maxTokens: Int = 2048
    ) -> AsyncThrowingStream<Generation, Error> {
        let stopped = OSAllocatedUnfairLock(initialState: false)
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in stopped.withLock { $0 = true } }
            queue.async {
                do {
                    let stats = try self.run(
                        messages, sampling: sampling, thinking: thinking, maxTokens: maxTokens,
                        isStopped: { stopped.withLock { $0 } }, emit: { continuation.yield($0) })
                    continuation.yield(.done(stats))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - On `queue`

    private func run(
        _ messages: [ChatMessage], sampling: Sampling, thinking: Thinking, maxTokens: Int,
        isStopped: () -> Bool, emit: (Generation) -> Void
    ) throws -> GenerationStats {
        var stats = GenerationStats()
        let batch = llama_batch_ext_init(ctx)!
        defer { llama_batch_ext_free(batch) }
        let limit = contextLength - Self.replyRoom
        var start = Date()

        let previous = transcript
        transcript = nil
        var appended = false
        if let previous, template.canContinue(from: previous.thinking, to: thinking),
           messages.count > previous.messages.count,
           Array(messages.prefix(previous.messages.count)) == previous.messages,
           messages[previous.messages.count...].allSatisfy({ $0.role == .user })
        {
            // Append only. Hybrid models (Inkling's short-conv layers) can't roll their state back,
            // so never rewinding is what makes multi-turn chat cheap on them.
            let tokens = try tokenize(template.renderContinuation(Array(messages[previous.messages.count...])))
            if cached.count + tokens.count <= limit {
                stats.reusedTokens = cached.count
                stats.promptTokens = cached.count + tokens.count
                try feed(tokens, batch: batch, isStopped: isStopped, emit: emit)
                appended = true
            }
            // Otherwise the earlier thinking has filled the cache: re-render without it below.
        }
        if !appended {
            let tokens = try tokenize(template.render(messages, thinking: thinking))
            guard !tokens.isEmpty else { throw LlamaError.tokenizeFailed }
            guard tokens.count <= limit else { throw LlamaError.contextFull }
            // Reuse a shared prefix where the model allows rewinding (attention-only models do).
            var keep = min(zip(cached, tokens).prefix { $0 == $1 }.count, tokens.count - 1)
            let mem = llama_get_memory(ctx)
            if keep < cached.count && !llama_memory_seq_rm(mem, 0, llama_pos(keep), -1) {
                llama_memory_clear(mem, true)
                keep = 0
            }
            cached = Array(tokens.prefix(keep))
            stats.reusedTokens = keep
            stats.promptTokens = tokens.count
            try feed(Array(tokens[keep...]), batch: batch, isStopped: isStopped, emit: emit)
        }
        stats.promptSeconds = Date().timeIntervalSince(start)
        if isStopped() { return stats }

        let smpl = makeSampler(sampling)
        defer { llama_sampler_free(smpl) }

        start = Date()
        var parser = template.makeParser()
        var utf8 = UTF8Assembler()
        var answer = ""
        var endedCleanly = false
        func send(_ text: String, marker: Bool, control: Bool = false) {
            switch parser.consume(text, marker: marker, control: control) {
            case .thinking(let t): emit(.thinking(t))
            case .text(let t):
                answer += t
                emit(.text(t))
            case nil: break
            }
        }
        while stats.generatedTokens < maxTokens, cached.count < contextLength, !isStopped() {
            let token = llama_sampler_sample(smpl, ctx, -1)
            if llama_vocab_is_eog(vocab, token) {
                // The turn-end token stays out of the cache; the next turn's continuation starts with it.
                endedCleanly = String(decoding: piece(token, special: true), as: UTF8.self) == template.turnEnd
                break
            }
            stats.generatedTokens += 1
            let attr = llama_vocab_get_attr(vocab, token).rawValue
            let control = attr & LLAMA_TOKEN_ATTR_CONTROL.rawValue != 0
            if control || attr & LLAMA_TOKEN_ATTR_USER_DEFINED.rawValue != 0 {
                if let rest = utf8.flush() { send(rest, marker: false) }
                send(String(decoding: piece(token, special: true), as: UTF8.self), marker: true, control: control)
            } else if let text = utf8.append(piece(token, special: false)) {
                send(text, marker: false)
            }
            try feed([token], batch: batch, isStopped: { false }, emit: { _ in })
        }
        if let rest = utf8.flush() { send(rest, marker: false) }
        stats.generateSeconds = Date().timeIntervalSince(start)
        if endedCleanly {
            transcript = (messages + [ChatMessage(role: .assistant, content: answer)], thinking)
        }
        return stats
    }

    /// Processes tokens in batch-size chunks, asking for logits only on the last one. Checks for a
    /// stop between chunks, since a long prompt on a big model can take tens of seconds.
    private func feed(
        _ tokens: [llama_token], batch: OpaquePointer, isStopped: () -> Bool, emit: (Generation) -> Void
    ) throws {
        var index = 0
        while index < tokens.count {
            if isStopped() { return }
            llama_batch_ext_clear(batch)
            let end = min(index + Self.batchSize, tokens.count)
            for i in index..<end {
                let idx = llama_batch_ext_add_token(batch, 0, tokens[i])
                guard idx >= 0 else { throw LlamaError.processFailed(idx) }
                var pos = llama_pos(cached.count + (i - index))
                _ = llama_batch_ext_set_pos(batch, idx, &pos)
                _ = llama_batch_ext_set_output_logits(batch, idx, i == tokens.count - 1)
            }
            let rc = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
            guard rc == 0 else { throw rc == 1 ? LlamaError.contextFull : LlamaError.processFailed(rc) }
            cached += tokens[index..<end]
            index = end
            if tokens.count > Self.batchSize { emit(.reading(Double(index) / Double(tokens.count))) }
        }
    }

    /// Special tokens in the text are parsed as special, as llama-server does: the templates rely on it.
    private func tokenize(_ text: String) throws -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var out = [llama_token](repeating: 0, count: utf8.count + 8)
        // Templates already include BOS where the model wants it, so add_special = false.
        var n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &out, Int32(out.count), false, true)
        if n < 0, n != Int32.min {
            out = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &out, Int32(out.count), false, true)
        }
        guard n >= 0 else { throw LlamaError.tokenizeFailed }
        return Array(out.prefix(Int(n)))
    }

    private func piece(_ token: llama_token, special: Bool) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, special)
        if n < 0, n != Int32.min {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, special)
        }
        return buf.prefix(Int(max(n, 0))).map { UInt8(bitPattern: $0) }
    }

    private func makeSampler(_ s: Sampling) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if s.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
            return chain
        }
        if s.topK > 0 { llama_sampler_chain_add(chain, llama_sampler_init_top_k(s.topK)) }
        if s.topP < 1 { llama_sampler_chain_add(chain, llama_sampler_init_top_p(s.topP, 1)) }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(s.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        return chain
    }
}

/// Token pieces can split a character's UTF-8 bytes. Emits everything up to the last complete
/// character and holds back at most an unfinished one.
struct UTF8Assembler {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> String? {
        pending += bytes
        var split = pending.count
        // Find the last lead byte within the final 4 bytes; if its sequence is incomplete, hold it.
        for back in 1...min(4, pending.count) {
            let byte = pending[pending.count - back]
            if byte & 0xC0 == 0x80 { continue }  // continuation byte
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if length > back { split = pending.count - back }
            break
        }
        guard split > 0 else { return nil }
        let text = String(decoding: pending[..<split], as: UTF8.self)
        pending.removeFirst(split)
        return text
    }

    mutating func flush() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

private final class ProgressBox {
    let callback: @Sendable (Float) -> Void
    init(_ callback: @escaping @Sendable (Float) -> Void) { self.callback = callback }
}
