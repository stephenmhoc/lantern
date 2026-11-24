import Foundation
import os
import llama

public struct ChatMessage: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant }
    public var role: Role
    public var content: String
    /// Encoded images (JPEG or PNG) shown to the model before `content`, on a model with a vision
    /// projector loaded (`loadVision`). Nil when there are none, so saved transcripts from before
    /// images existed still decode and compare equal.
    public var images: [Data]?
    public init(role: Role, content: String, images: [Data] = []) {
        self.role = role
        self.content = content
        self.images = images.isEmpty ? nil : images
    }

    public var hasImages: Bool { !(images ?? []).isEmpty }
    /// The same turn, text only: what a model without vision sees.
    public var withoutImages: ChatMessage { ChatMessage(role: role, content: content) }
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

/// Why a reply ended. Anything but `.end` means it was cut short.
public enum StopReason: String, Sendable, Codable {
    /// The model finished its turn.
    case end
    /// It ran into the reply-length limit (`maxTokens`).
    case maxTokens
    /// The context window filled up mid-reply.
    case contextFull
    /// The reader stopped iterating.
    case stopped
}

/// How a model is loaded. The defaults suit a model that is bigger than memory (Inkling).
public struct ModelOptions: Sendable, Hashable {
    public var contextLength: UInt32
    /// llama.cpp's `lazy_mode`: reads the rows of per-layer token-embedding tables from storage as
    /// they're used instead of prefetching the whole table. Only architectures that mark such a
    /// tensor are affected (Gemma 4's 1.2 GB table); it does nothing for Inkling's MoE experts,
    /// which are paged by mmap alone.
    public var lazyEmbeddings: Bool
    /// F16 instead of Q8_0 for the KV cache: twice the memory, faster attention on models whose
    /// cache is small (Gemma). Not worth it on Inkling, whose cache is ten times larger.
    public var f16Cache: Bool
    /// Keeps a mixture-of-experts model's expert weights (`ffn_*_exps`) on the CPU, read straight
    /// from the memory-mapped file, and puts only the rest (attention, shared layers, a few hundred
    /// MB) on the GPU. Needed when the whole model is more than iOS lets the GPU use: Metal then
    /// fails the first command buffer (llama.cpp's error -3). Slower than all-GPU, but it runs.
    public var expertsOnCPU: Bool

    public init(
        contextLength: UInt32 = 8192, lazyEmbeddings: Bool = false, f16Cache: Bool = false, expertsOnCPU: Bool = false
    ) {
        self.contextLength = contextLength
        self.lazyEmbeddings = lazyEmbeddings
        self.f16Cache = f16Cache
        self.expertsOnCPU = expertsOnCPU
    }
}

public struct GenerationStats: Sendable {
    public var stopReason = StopReason.end
    /// Whether the prompt continued a saved checkpoint or the in-memory system-prompt snapshot.
    public var restored = false
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
    case cancelled
    /// The vision projector couldn't be loaded, or isn't one this model can use.
    case visionFailed
    /// An image couldn't be read (not a JPEG, PNG or other format stb_image knows).
    case imageFailed

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let path): "Couldn't load the model at \(path)."
        case .unsupportedModel: "Lantern doesn't know this model's chat format."
        case .contextFailed: "Couldn't create a context. The device may be out of memory."
        case .tokenizeFailed: "Couldn't tokenize the prompt."
        case .contextFull: "This chat is too long for the model. Start a new chat."
        case .processFailed(let code): "The model stopped with error \(code)."
        case .cancelled: "Stopped."
        case .visionFailed: "Couldn't load the model's image reader."
        case .imageFailed: "Couldn't read the image."
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
    /// Where the current `transcript` still has to be saved, if it hasn't been.
    private var unsaved: URL?
    /// Hybrid models only: the state right after the system prompt, kept in memory so a new chat,
    /// a stopped reply or a retry can start from it instead of from nothing.
    private var prefixSnapshot: (tokens: [llama_token], data: [UInt8])?
    private let used = OSAllocatedUnfairLock(initialState: 0)
    private let threads: Int32
    /// The vision projector (`mtmd_context`), once `loadVision` has loaded one.
    private var vision: OpaquePointer?
    private let visionLoaded = OSAllocatedUnfairLock(initialState: false)

    public let contextLength: Int
    /// False for hybrid and recurrent models (Inkling): their state can't be rolled back, so the
    /// cache is only ever appended to, restored from a checkpoint, or cleared.
    public let canRewind: Bool
    /// Identifies the file and the context settings a saved state belongs to.
    public let stateKey: String
    /// Tokens in the cache right now. Cheap to read from any thread.
    public var tokensInContext: Int { used.withLock { $0 } }
    /// The longest prompt accepted: the context less the room kept for the reply.
    public var promptLimit: Int { contextLength - Self.replyRoom }
    public var sizeBytes: UInt64 { llama_model_size(model) }
    public var templateName: String { template.format.rawValue }
    /// Whether images in messages are shown to the model. Without a projector they're left out.
    public var hasVision: Bool { visionLoaded.withLock { $0 } }
    /// About how many tokens an image takes (the projector is capped at this), for counting a
    /// prompt before its images are encoded.
    public static let imageTokens = 280

    private static let backend: Void = llama_backend_init()
    private static let batchSize = 512
    /// The performance cores, up to six. Each op is split evenly across the threads and waits for
    /// the slowest, so a thread on an efficiency core holds the rest back.
    private static let threadCount: Int32 = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) != 0 || cores < 1 {
            cores = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        }
        return max(1, min(cores, 6))
    }()
    /// Room kept free for the reply; a prompt that leaves less is treated as too long.
    private static let replyRoom = 1024

    /// Loads synchronously; call from a background task. The file is memory-mapped, which is what
    /// lets a model bigger than the app's memory limit run: its pages are clean and the OS brings
    /// them in from storage as they're used. Returning true from `isCancelled` abandons the load
    /// (checked as each part of the file is mapped) and throws `LlamaError.cancelled`.
    public init(
        path: String, options: ModelOptions = ModelOptions(),
        progress: (@Sendable (Float) -> Void)? = nil, isCancelled: (@Sendable () -> Bool)? = nil
    ) throws {
        _ = Self.backend
        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        mp.load_mode = LLAMA_LOAD_MODE_MMAP
        mp.lazy_mode = options.lazyEmbeddings ? LLAMA_LAZY_MODE_ON : LLAMA_LAZY_MODE_OFF
        let box = Unmanaged.passRetained(ProgressBox(progress, isCancelled))
        defer { box.release() }
        mp.progress_callback = { value, data in
            let box = Unmanaged<ProgressBox>.fromOpaque(data!).takeUnretainedValue()
            box.progress?(value)
            return box.isCancelled?() != true
        }
        mp.progress_callback_user_data = box.toOpaque()
        #if targetEnvironment(simulator)
        // The simulator's Metal driver aborts on llama.cpp's host-memory buffers: CPU only there.
        var devices: [ggml_backend_dev_t?] = [ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU), nil]
        mp.n_gpu_layers = 0
        let loaded = devices.withUnsafeMutableBufferPointer { buf in
            mp.devices = buf.baseAddress
            return llama_model_load_from_file(path, mp)
        }
        #else
        let loaded: OpaquePointer?
        if options.expertsOnCPU {
            // The pattern must outlive the load; the list ends with a null entry.
            let pattern = strdup("\\.ffn_(up|down|gate|gate_up)_exps")
            defer { free(pattern) }
            let overrides = [
                llama_model_tensor_buft_override(pattern: pattern, buft: ggml_backend_cpu_buffer_type()),
                llama_model_tensor_buft_override(pattern: nil, buft: nil),
            ]
            loaded = overrides.withUnsafeBufferPointer { buf in
                mp.tensor_buft_overrides = buf.baseAddress
                return llama_model_load_from_file(path, mp)
            }
        } else {
            loaded = llama_model_load_from_file(path, mp)
        }
        #endif
        guard let model = loaded else {
            throw isCancelled?() == true ? LlamaError.cancelled : LlamaError.loadFailed(path)
        }
        guard let template = ChatTemplate(model: model) else {
            llama_model_free(model)
            throw LlamaError.unsupportedModel
        }

        var cp = llama_context_default_params()
        let canRewind = !llama_model_is_hybrid(model) && !llama_model_is_recurrent(model)
        cp.n_ctx = options.contextLength
        cp.n_batch = UInt32(Self.batchSize)
        cp.n_ubatch = UInt32(Self.batchSize)
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        if !options.f16Cache {
            cp.type_k = GGML_TYPE_Q8_0  // half the memory of f16 for a small quality cost
            cp.type_v = GGML_TYPE_Q8_0
        }
        // A model that can't rewind has no use for sliding-window layers remembering more than
        // their window: on Inkling that is 550 MB less cache and a slightly faster prefill.
        cp.swa_full = canRewind
        let threads = Self.threadCount
        cp.n_threads = threads
        cp.n_threads_batch = threads
        #if targetEnvironment(simulator)
        cp.offload_kqv = false
        cp.op_offload = false
        #else
        // With the experts left in CPU memory, offloading a prompt's expert matmuls to the GPU
        // means copying the expert weights there for every batch, which needs gigabytes of GPU
        // scratch on a device that kept them off the GPU for lack of room. Run them where they are.
        if options.expertsOnCPU { cp.op_offload = false }
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
        self.canRewind = canRewind
        self.threads = threads
        let file = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        self.stateKey = [
            "v1", URL(fileURLWithPath: path).lastPathComponent, "\(file?.fileSize ?? 0)",
            "\(Int(file?.contentModificationDate?.timeIntervalSince1970 ?? 0))",
            "ctx\(llama_n_ctx(ctx))", options.f16Cache ? "f16" : "q8", canRewind ? "full" : "swa",
        ].joined(separator: "|")
    }

    deinit {
        if let vision { mtmd_free(vision) }
        llama_free(ctx)
        llama_model_free(model)
    }

    /// Streams the reply. Generations queue behind each other; each has its own stop flag, set when
    /// the reader stops iterating, so stopping one can never stop the next.
    ///
    /// `checkpoint` is a directory for this conversation's saved state. When the cache doesn't
    /// already hold the conversation, a matching state found there is loaded instead of reading
    /// the chat again, and the new state is saved there once the reply ends cleanly.
    public func generate(
        _ messages: [ChatMessage], sampling: Sampling, thinking: Thinking = .off, maxTokens: Int = 2048,
        checkpoint: URL? = nil
    ) -> AsyncThrowingStream<Generation, Error> {
        let stopped = OSAllocatedUnfairLock(initialState: false)
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in stopped.withLock { $0 = true } }
            queue.async {
                do {
                    let stats = try self.run(
                        messages, sampling: sampling, thinking: thinking, maxTokens: maxTokens, checkpoint: checkpoint,
                        isStopped: { stopped.withLock { $0 } }, emit: { continuation.yield($0) })
                    continuation.yield(.done(stats))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                self.used.withLock { $0 = self.cached.count }
                // After the reader has its answer: saving can take a moment on a long chat.
                self.saveCheckpoint()
            }
        }
    }

    /// Loads a vision projector (an mmproj GGUF made for this model) so images in messages are
    /// seen. Costs its size in memory until the model is freed. Does nothing if one is loaded.
    public func loadVision(projector path: String) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.vision == nil else { return done.resume() }
                var p = mtmd_context_params_default()
                #if targetEnvironment(simulator)
                p.use_gpu = false  // as for the model: the simulator's Metal can't run llama.cpp
                #endif
                p.print_timings = false
                p.warmup = false
                p.n_threads = self.threads
                // Images must fit one batch (Gemma attends across an image's tokens at once), and
                // fewer tokens is a faster encode on a phone.
                p.image_max_tokens = Int32(Self.imageTokens)
                guard let vision = mtmd_init_from_file(path, self.model, p) else {
                    return done.resume(throwing: LlamaError.visionFailed)
                }
                // Positions are tracked one per token, which M-RoPE models (Qwen-VL) don't follow.
                guard mtmd_support_vision(vision), !mtmd_decode_use_mrope(vision) else {
                    mtmd_free(vision)
                    return done.resume(throwing: LlamaError.visionFailed)
                }
                self.vision = vision
                self.visionLoaded.withLock { $0 = true }
                done.resume()
            }
        }
    }

    // MARK: - On `queue`

    /// What the model can be shown: images only with a projector loaded.
    private func visible(_ messages: [ChatMessage]) -> [ChatMessage] {
        vision == nil && messages.contains(where: \.hasImages) ? messages.map(\.withoutImages) : messages
    }

    private func run(
        _ input: [ChatMessage], sampling: Sampling, thinking: Thinking, maxTokens: Int, checkpoint: URL?,
        isStopped: () -> Bool, emit: (Generation) -> Void
    ) throws -> GenerationStats {
        var stats = GenerationStats()
        let batch = llama_batch_ext_init(ctx)!
        defer { llama_batch_ext_free(batch) }
        let limit = promptLimit
        var start = Date()
        let messages = visible(input)
        // A chat with images is always rendered in full: the images' stand-in tokens let the
        // shared prefix be reused, so only new turns (and new images) are processed. Only models
        // that can rewind have projectors here (Gemma).
        let multimodal = messages.contains(where: \.hasImages)

        // The turns to add if the cache holds an earlier point of this conversation: what's live,
        // or else what was saved for it.
        var rest = multimodal ? nil : continuation(of: transcript, to: messages, thinking: thinking)
        if rest == nil, !multimodal, let checkpoint {
            for slot in Slot.allCases {
                guard let saved = savedTranscript(in: checkpoint, slot),
                      let fromSaved = continuation(of: (saved.messages, saved.thinking), to: messages, thinking: thinking),
                      restore(from: checkpoint, slot, tokens: saved.tokens) else { continue }
                rest = fromSaved
                stats.restored = true
                break
            }
        }
        transcript = nil
        unsaved = nil
        var appended = false
        if let rest {
            // Append only. Hybrid models (Inkling's short-conv layers) can't roll their state back,
            // so never rewinding is what makes multi-turn chat cheap on them.
            let tokens = try tokenize(template.renderContinuation(rest))
            if cached.count + tokens.count <= limit {
                stats.reusedTokens = cached.count
                stats.promptTokens = cached.count + tokens.count
                try feed(tokens, batch: batch, isStopped: isStopped, emit: emit)
                appended = true
            }
            // Otherwise the earlier thinking has filled the cache: re-render without it below.
        }
        if !appended, multimodal {
            let prompt = try multimodalPrompt(template.render(messages, thinking: thinking),
                                              images: messages.flatMap { $0.images ?? [] })
            defer { mtmd_input_chunks_free(prompt.chunks) }
            guard prompt.tokens.count <= limit else { throw LlamaError.contextFull }
            stats.reusedTokens = reuse(prompt)
            stats.promptTokens = prompt.tokens.count
            try feed(prompt, batch: batch, isStopped: isStopped, emit: emit)
        } else if !appended {
            let tokens = try tokenize(template.render(messages, thinking: thinking))
            guard !tokens.isEmpty else { throw LlamaError.tokenizeFailed }
            guard tokens.count <= limit else { throw LlamaError.contextFull }
            let keep = try reuse(tokens, systemPrefix: systemPrefix(messages, thinking: thinking, of: tokens), batch: batch)
            if keep.restored { stats.restored = true }
            stats.reusedTokens = keep.count
            stats.promptTokens = tokens.count
            try feed(Array(tokens[cached.count...]), batch: batch, isStopped: isStopped, emit: emit)
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
        var ended = false
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
                ended = true
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
        if !ended {
            stats.stopReason = isStopped() ? .stopped : stats.generatedTokens >= maxTokens ? .maxTokens : .contextFull
        }
        if endedCleanly {
            transcript = (messages + [ChatMessage(role: .assistant, content: answer)], thinking)
            // Worth saving only if a later turn could continue it (not Gemma with thinking on).
            if template.canContinue(from: thinking, to: thinking) { unsaved = checkpoint }
        }
        return stats
    }

    /// The messages after `base` if `messages` extends it in a way the cache can follow: same
    /// thinking setting, and ending with the user's turn. A model that can rewind only appends
    /// user turns (anything else is re-rendered and the shared prefix reused); one that can't also
    /// appends earlier replies as plain history, e.g. a stopped answer, since its only other
    /// option is reading everything again.
    private func continuation(
        of base: (messages: [ChatMessage], thinking: Thinking)?, to messages: [ChatMessage], thinking: Thinking
    ) -> [ChatMessage]? {
        guard let base, template.canContinue(from: base.thinking, to: thinking),
              messages.count > base.messages.count, messages.last?.role == .user,
              Array(messages.prefix(base.messages.count)) == base.messages else { return nil }
        let rest = Array(messages[base.messages.count...])
        guard rest.allSatisfy({ $0.role == .user || (!canRewind && $0.role == .assistant) }) else { return nil }
        return rest
    }

    /// Makes the cache hold the longest prefix of `tokens` it can and returns how many tokens were
    /// reused. Where the model allows rewinding (attention-only models do), that's the shared
    /// prefix. Where it doesn't, it's the whole cache if `tokens` extends it, else the system-prompt
    /// snapshot, else nothing; starting from nothing, the system prompt is read first and
    /// snapshotted for next time.
    private func reuse(
        _ tokens: [llama_token], systemPrefix: Int?, batch: OpaquePointer
    ) throws -> (count: Int, restored: Bool) {
        var keep = min(zip(cached, tokens).prefix { $0 == $1 }.count, tokens.count - 1)
        var restored = false
        if keep < cached.count {
            let mem = llama_get_memory(ctx)
            if canRewind, llama_memory_seq_rm(mem, 0, llama_pos(keep), -1) {
                cached = Array(tokens.prefix(keep))
            } else if !canRewind, let snapshot = prefixSnapshot, snapshot.tokens.count < tokens.count,
                      tokens.starts(with: snapshot.tokens), restore(snapshot)
            {
                keep = cached.count
                restored = true
            } else {
                llama_memory_clear(mem, true)
                cached = []
                keep = 0
            }
        }
        if !canRewind, cached.isEmpty, let systemPrefix {
            try feed(Array(tokens[..<systemPrefix]), batch: batch, isStopped: { false }, emit: { _ in })
            takePrefixSnapshot()
        }
        return (keep, restored)
    }

    /// How many of `tokens` are the system prompt, if the conversation starts with one.
    private func systemPrefix(_ messages: [ChatMessage], thinking: Thinking, of tokens: [llama_token]) -> Int? {
        guard let text = template.renderSystemPrefix(messages, thinking: thinking),
              let prefix = try? tokenize(text), !prefix.isEmpty, prefix.count < tokens.count,
              tokens.starts(with: prefix) else { return nil }
        return prefix.count
    }

    // MARK: - Images (on `queue`)

    /// A prompt with images, tokenized by the projector. `tokens` has every position: text
    /// tokens as they are, and for each image a run of stand-ins derived from its bytes (negative,
    /// so never a real token). Comparing them with `cached` finds the shared prefix as for text.
    private struct MultimodalPrompt {
        struct Span {
            let range: Range<Int>
            let chunk: OpaquePointer  // mtmd_input_chunk, owned by `chunks`
            let isImage: Bool
        }
        let chunks: OpaquePointer  // mtmd_input_chunks; the caller frees it
        var tokens: [llama_token] = []
        var spans: [Span] = []
    }

    private func multimodalPrompt(_ text: String, images: [Data]) throws -> MultimodalPrompt {
        guard let vision, let chunks = mtmd_input_chunks_init() else { throw LlamaError.visionFailed }
        var bitmaps: [OpaquePointer?] = []
        defer { bitmaps.forEach { mtmd_bitmap_free($0) } }
        for data in images {
            let wrapper = data.withUnsafeBytes { raw in
                mtmd_helper_bitmap_init_from_buf(
                    vision, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, false, mtmd_helper_init_opt_default())
            }
            guard let bitmap = wrapper.bitmap else {
                mtmd_input_chunks_free(chunks)
                throw LlamaError.imageFailed
            }
            bitmaps.append(bitmap)
        }
        let rc = text.withCString { cText in
            var input = mtmd_input_text(text: cText, text_len: strlen(cText), add_special: false, parse_special: true)
            return bitmaps.withUnsafeBufferPointer { mtmd_tokenize(vision, chunks, &input, $0.baseAddress, $0.count) }
        }
        guard rc == 0 else {
            mtmd_input_chunks_free(chunks)
            throw rc == 2 ? LlamaError.imageFailed : LlamaError.tokenizeFailed
        }
        var prompt = MultimodalPrompt(chunks: chunks)
        var image = 0
        for i in 0..<mtmd_input_chunks_size(chunks) {
            guard let chunk = mtmd_input_chunks_get(chunks, i) else { continue }
            let start = prompt.tokens.count
            let isImage = mtmd_input_chunk_get_type(chunk) != MTMD_INPUT_CHUNK_TYPE_TEXT
            if isImage {
                let standIn = images.indices.contains(image) ? Self.standIn(for: images[image]) : -1
                image += 1
                prompt.tokens += repeatElement(standIn, count: mtmd_input_chunk_get_n_tokens(chunk))
            } else {
                var n = 0
                if let text = mtmd_input_chunk_get_tokens_text(chunk, &n) { prompt.tokens += UnsafeBufferPointer(start: text, count: n) }
            }
            prompt.spans.append(.init(range: start..<prompt.tokens.count, chunk: chunk, isImage: isImage))
        }
        return prompt
    }

    /// The same image always gets the same stand-in, a different one almost never does (FNV-1a).
    private static func standIn(for image: Data) -> llama_token {
        var hash: UInt32 = 2_166_136_261
        for byte in image { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return -1 - llama_token(hash & 0x3FFF_FFFF)
    }

    /// Like `reuse` for text, on a model that can rewind: keeps the shared prefix, but never part
    /// of an image (an image is encoded whole). Returns how many positions were kept.
    private func reuse(_ prompt: MultimodalPrompt) -> Int {
        var keep = min(zip(cached, prompt.tokens).prefix { $0 == $1 }.count, prompt.tokens.count - 1)
        if let split = prompt.spans.first(where: { $0.isImage && $0.range.contains(keep) && $0.range.lowerBound < keep }) {
            keep = split.range.lowerBound
        }
        if keep < cached.count {
            let mem = llama_get_memory(ctx)
            if canRewind, llama_memory_seq_rm(mem, 0, llama_pos(keep), -1) {
                cached = Array(cached.prefix(keep))
            } else {
                llama_memory_clear(mem, true)
                cached = []
                keep = 0
            }
        }
        return keep
    }

    /// Processes what the cache doesn't hold yet: text as usual, each new image encoded by the
    /// projector and decoded into the context.
    private func feed(
        _ prompt: MultimodalPrompt, batch: OpaquePointer, isStopped: () -> Bool, emit: (Generation) -> Void
    ) throws {
        guard let vision else { throw LlamaError.visionFailed }
        let total = Double(prompt.tokens.count)
        for span in prompt.spans where span.range.upperBound > cached.count {
            if isStopped() { return }
            emit(.reading(Double(cached.count) / total))
            if span.isImage {
                var past: llama_pos = 0
                let rc = mtmd_helper_eval_chunk_single(
                    vision, ctx, span.chunk, llama_pos(cached.count), 0, Int32(Self.batchSize), false, &past)
                guard rc == 0 else { throw LlamaError.processFailed(rc) }
                cached += prompt.tokens[span.range]
                guard Int(past) == cached.count else { throw LlamaError.processFailed(-2) }
                used.withLock { $0 = cached.count }
            } else {
                let from = max(span.range.lowerBound, cached.count)
                try feed(Array(prompt.tokens[from..<span.range.upperBound]), batch: batch, isStopped: isStopped, emit: { _ in })
            }
        }
    }

    // MARK: - Saved state (on `queue`)

    private struct SavedTranscript: Codable {
        var key: String
        var thinking: Thinking
        var messages: [ChatMessage]
        var tokens: Int
    }

    /// A conversation's directory holds its latest clean turn end and, for a model that can't
    /// rewind, the one before: what Retry goes back to.
    private enum Slot: String, CaseIterable { case latest, previous }

    private static func stateFile(_ directory: URL, _ slot: Slot) -> URL { directory.appending(path: "\(slot.rawValue).state") }
    private static func metaFile(_ directory: URL, _ slot: Slot) -> URL { directory.appending(path: "\(slot.rawValue).json") }

    /// The conversation a checkpoint holds, if it was made by this model file with these settings.
    private func savedTranscript(in directory: URL, _ slot: Slot) -> SavedTranscript? {
        guard let data = try? Data(contentsOf: Self.metaFile(directory, slot)),
              let saved = try? JSONDecoder().decode(SavedTranscript.self, from: data),
              saved.key == stateKey else { return nil }
        return saved
    }

    /// Replaces the cache with a saved state. On any failure the cache is left empty.
    private func restore(from directory: URL, _ slot: Slot, tokens expected: Int) -> Bool {
        llama_memory_clear(llama_get_memory(ctx), true)
        cached = []
        var tokens = [llama_token](repeating: 0, count: contextLength)
        var count = 0
        let read = llama_state_seq_load_file(ctx, Self.stateFile(directory, slot).path, 0, &tokens, tokens.count, &count)
        guard read > 0, count == expected else {
            llama_memory_clear(llama_get_memory(ctx), true)
            return false
        }
        cached = Array(tokens.prefix(count))
        return true
    }

    /// Writes the cache and the transcript it holds, if a clean turn end left one to save. The
    /// transcript goes last and comes out first, so a half-written state is never trusted.
    private func saveCheckpoint() {
        guard let directory = unsaved, let transcript else { return }
        let fm = FileManager.default
        let state = Self.stateFile(directory, .latest), meta = Self.metaFile(directory, .latest)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !canRewind, let latest = savedTranscript(in: directory, .latest),
           latest.messages.count < transcript.messages.count, transcript.messages.starts(with: latest.messages)
        {
            // The turn before this one. A sibling (the reply a retry replaced) is overwritten instead.
            let oldState = Self.stateFile(directory, .previous), oldMeta = Self.metaFile(directory, .previous)
            try? fm.removeItem(at: oldMeta)
            try? fm.removeItem(at: oldState)
            if (try? fm.moveItem(at: state, to: oldState)) != nil { try? fm.moveItem(at: meta, to: oldMeta) }
        }
        try? fm.removeItem(at: meta)
        guard llama_state_seq_save_file(ctx, state.path, 0, cached, cached.count) > 0 else {
            try? fm.removeItem(at: state)
            return
        }
        let saved = SavedTranscript(key: stateKey, thinking: transcript.thinking, messages: transcript.messages, tokens: cached.count)
        guard let data = try? JSONEncoder().encode(saved), (try? data.write(to: meta, options: .atomic)) != nil else { return }
        unsaved = nil
    }

    /// Legacy directories already looked at by this model, so adopting costs nothing after the first time.
    private var adoptedFrom: Set<URL> = []

    private func adopt(from legacy: URL, into directory: URL) {
        guard legacy.standardizedFileURL != directory.standardizedFileURL,
              adoptedFrom.insert(legacy.standardizedFileURL).inserted else { return }
        let fm = FileManager.default
        let file = stateKey.split(separator: "|").dropFirst().first
        for slot in Slot.allCases {
            let state = Self.stateFile(legacy, slot), meta = Self.metaFile(legacy, slot)
            let hasState = fm.fileExists(atPath: state.path), hasMeta = fm.fileExists(atPath: meta.path)
            guard hasState || hasMeta else { continue }
            let key = (try? Data(contentsOf: meta)).flatMap { try? JSONDecoder().decode(SavedTranscript.self, from: $0) }?.key
            if let key, key.split(separator: "|").dropFirst().first != file { continue }  // another model's: left for it
            if hasState, key == stateKey, !fm.fileExists(atPath: Self.metaFile(directory, slot).path) {
                try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
                // State first, transcript last: a state is trusted only with its transcript.
                try? fm.removeItem(at: Self.stateFile(directory, slot))
                if (try? fm.moveItem(at: state, to: Self.stateFile(directory, slot))) != nil,
                   (try? fm.moveItem(at: meta, to: Self.metaFile(directory, slot))) != nil { continue }
            }
            // This model's with other settings or file (never usable), already superseded in
            // `directory`, half-written or unreadable: nothing will ever adopt it.
            try? fm.removeItem(at: meta)
            try? fm.removeItem(at: state)
        }
    }

    private func takePrefixSnapshot() {
        let size = llama_state_seq_get_size(ctx, 0)
        var data = [UInt8](repeating: 0, count: size)
        guard size > 0, llama_state_seq_get_data(ctx, &data, size, 0) == size else { return }
        prefixSnapshot = (cached, data)
    }

    private func restore(_ snapshot: (tokens: [llama_token], data: [UInt8])) -> Bool {
        llama_memory_clear(llama_get_memory(ctx), true)
        cached = []
        guard llama_state_seq_set_data(ctx, snapshot.data, snapshot.data.count, 0) > 0 else {
            llama_memory_clear(llama_get_memory(ctx), true)
            prefixSnapshot = nil
            return false
        }
        cached = snapshot.tokens
        return true
    }

    // MARK: - Between generations

    /// Gets the cache ready for the next message of a conversation, so sending doesn't wait for it:
    /// loads the conversation's checkpoint if the cache holds something else, or for a new chat
    /// reads the system prompt. `messages` is what the model has seen so far (the system prompt and
    /// any history). Queues behind a running generation.
    public func prepare(_ messages: [ChatMessage], thinking: Thinking, checkpoint: URL?) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.warm(messages, thinking: thinking, checkpoint: checkpoint)
                self.used.withLock { $0 = self.cached.count }
                done.resume()
            }
        }
    }

    private func warm(_ messages: [ChatMessage], thinking: Thinking, checkpoint: URL?) {
        if let transcript, messages.starts(with: transcript.messages) { return }  // already this chat
        saveCheckpoint()
        if messages.count > 1 {
            // A chat with history: only its saved state helps. Reading the whole chat again is
            // left for when a message is actually sent.
            guard let checkpoint else { return }
            for slot in Slot.allCases {
                guard let saved = savedTranscript(in: checkpoint, slot), messages.starts(with: saved.messages) else { continue }
                transcript = restore(from: checkpoint, slot, tokens: saved.tokens) ? (saved.messages, saved.thinking) : nil
                return
            }
            return
        }
        guard let text = template.renderSystemPrefix(messages, thinking: thinking),
              let tokens = try? tokenize(text), !tokens.isEmpty, tokens.count <= promptLimit,
              cached != tokens else { return }
        transcript = nil
        let batch = llama_batch_ext_init(ctx)!
        defer { llama_batch_ext_free(batch) }
        if !canRewind, let snapshot = prefixSnapshot, snapshot.tokens == tokens, restore(snapshot) { return }
        let keep = canRewind ? zip(cached, tokens).prefix { $0 == $1 }.count : 0
        if keep < cached.count, !(canRewind && llama_memory_seq_rm(llama_get_memory(ctx), 0, llama_pos(keep), -1)) {
            llama_memory_clear(llama_get_memory(ctx), true)
            cached = []
        } else {
            cached = Array(tokens.prefix(keep))
        }
        guard (try? feed(Array(tokens[cached.count...]), batch: batch, isStopped: { false }, emit: { _ in })) != nil else {
            llama_memory_clear(llama_get_memory(ctx), true)
            cached = []
            return
        }
        if !canRewind { takePrefixSnapshot() }
    }

    /// Saves the current conversation's state if a clean turn end hasn't been saved yet (normally it
    /// has, right after the reply). Call before the model is dropped or the app is suspended.
    /// Moves a conversation's state saved in `legacy` (where it sat before each model had a
    /// directory of its own) into `directory`, if this model file made it with these settings.
    /// Queued like a generation, so the `generate` or `prepare` called after it sees the result;
    /// looks at each legacy directory once per load, so it's free to call every time. A legacy
    /// state of this model that can't be used (other settings, an older file, already superseded
    /// in `directory`, or half-written) is deleted; another model's is left for that model.
    public func adoptLegacyState(from legacy: URL, into directory: URL) {
        queue.async { self.adopt(from: legacy, into: directory) }
    }

    public func flush() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.saveCheckpoint()
                done.resume()
            }
        }
    }

    /// How many tokens `messages` take as a prompt.
    public func countTokens(_ messages: [ChatMessage], thinking: Thinking = .off) async -> Int {
        await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
            queue.async {
                // Images count at their capped size when they'll be seen; their markers aren't text.
                let images = self.vision == nil ? 0 : messages.reduce(0) { $0 + ($1.images?.count ?? 0) }
                let text = messages.map(\.withoutImages)
                let count = (try? self.tokenize(self.template.render(text, thinking: thinking)).count) ?? 0
                done.resume(returning: count + images * Self.imageTokens)
            }
        }
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
            used.withLock { $0 = cached.count }
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
    let progress: (@Sendable (Float) -> Void)?
    let isCancelled: (@Sendable () -> Bool)?
    init(_ progress: (@Sendable (Float) -> Void)?, _ isCancelled: (@Sendable () -> Bool)?) {
        self.progress = progress
        self.isCancelled = isCancelled
    }
}
