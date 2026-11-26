import Accelerate
import Foundation
import os
#if canImport(llama)
import llama
#endif

public struct ChatMessage: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant }
    public var role: Role
    public var content: String
    /// Encoded images (JPEG or PNG) shown to the model before `content`, on a model with a vision
    /// projector loaded (`loadVision`). Nil when there are none, so saved transcripts from before
    /// images existed still decode and compare equal.
    public var images: [Data]?
    /// On a reply: the web searches the model ran before writing `content`, in order. Each goes
    /// back to the model as its call and result, ahead of the answer. Nil when there were none, so
    /// saved transcripts from before searching existed still decode and compare equal.
    public var searches: [WebSearch]?
    /// On the system message: the tools declared to the model (`WebSearch.toolName`), which the
    /// templates put in the system turn. Part of the message, so a chat whose tools change no
    /// longer matches its cache or saved state, exactly as its prompt wouldn't. Nil for none.
    public var tools: [String]?
    public init(role: Role, content: String, images: [Data] = [], searches: [WebSearch] = [], tools: [String] = []) {
        self.role = role
        self.content = content
        self.images = images.isEmpty ? nil : images
        self.searches = searches.isEmpty ? nil : searches
        self.tools = tools.isEmpty ? nil : tools
    }

    /// Whether this (system) message declares web search.
    public var declaresWebSearch: Bool { tools?.contains(WebSearch.toolName) == true }

    public var hasImages: Bool { !(images ?? []).isEmpty }
    /// The same turn, text only: what a model without vision sees.
    public var withoutImages: ChatMessage {
        ChatMessage(role: role, content: content, searches: searches ?? [], tools: tools ?? [])
    }
}

public struct Sampling: Sendable, Hashable {
    public var temperature: Float
    public var topK: Int32  // 0 = off
    public var topP: Float  // 1 = off
    public var minP: Float  // 0 = off
    /// Subtracted from the logit of every token already in the reply (llama.cpp's penalties
    /// sampler, presence only, over the reply so far). 0 = off.
    public var presencePenalty: Float
    public init(temperature: Float, topK: Int32 = 0, topP: Float = 1, minP: Float = 0, presencePenalty: Float = 0) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.presencePenalty = presencePenalty
    }

    /// Qwen 3.5's recommended settings (its model card), with and without thinking.
    public static func qwen35(thinking: Bool) -> Sampling {
        thinking
            ? Sampling(temperature: 1.0, topK: 20, topP: 0.95, presencePenalty: 1.5)
            : Sampling(temperature: 0.7, topK: 20, topP: 0.8, presencePenalty: 1.5)
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

/// How a model is loaded.
public struct ModelOptions: Sendable, Hashable {
    public var contextLength: UInt32
    /// llama.cpp's `lazy_mode`: reads the rows of per-layer token-embedding tables from storage as
    /// they're used instead of prefetching the whole table. Only architectures that mark such a
    /// tensor are affected (Gemma 4's 1.2 GB table).
    public var lazyEmbeddings: Bool
    /// F16 instead of Q8_0 for the KV cache: twice the memory, faster attention on models whose
    /// cache is small (Gemma).
    public var f16Cache: Bool
    /// An MTP draft model made for this one (Gemma 4's `mtp-gemma-4-*-it.gguf`, about 60 MB): each
    /// step it guesses the next `draftTokens` tokens, the model checks them in one batch and keeps
    /// the ones it would have picked itself, so the reply is the same, sooner. Used only on a model
    /// that can rewind (rejected guesses are removed from the cache); ignored if it can't be loaded
    /// or doesn't fit the model.
    public var draftModel: String?
    /// The most tokens drafted per step.
    public var draftTokens: Int
    /// Tokens per batch when reading a prompt (`n_batch` and `n_ubatch`). Bigger reads long prompts
    /// faster but takes more compute memory.
    public var batchSize: Int
    /// A draft stops at a token the drafter is less sure of than this (llama.cpp's `p_min`).
    public var draftMinProbability: Float = 0.5
    /// Whether sliding-window layers keep the whole context (needed to rewind anywhere) or only
    /// their window plus a batch. Nil: full for a model that can rewind.
    public var fullWindowCache: Bool?

    public init(
        contextLength: UInt32 = 8192, lazyEmbeddings: Bool = false, f16Cache: Bool = false,
        draftModel: String? = nil, draftTokens: Int = 3, batchSize: Int = 1024
    ) {
        self.contextLength = contextLength
        self.lazyEmbeddings = lazyEmbeddings
        self.f16Cache = f16Cache
        self.draftModel = draftModel
        self.draftTokens = draftTokens
        self.batchSize = batchSize
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
    /// Tokens the MTP draft model guessed, and how many of them the model kept.
    public var draftedTokens = 0
    public var acceptedDraftTokens = 0
    public init() {}
    public var tokensPerSecond: Double { generateSeconds > 0 ? Double(generatedTokens) / generateSeconds : 0 }
}

public enum Generation: Sendable {
    /// Share of the prompt processed so far; sent between chunks of a long prompt.
    case reading(Double)
    case thinking(String)
    case text(String)
    /// The model asked to search the web for this; the results follow as `.searched`.
    case searching(String)
    case searched(WebSearch)
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

#if canImport(llama)
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
    private let batchSize: Int
    /// The vision projector (`mtmd_context`), once `loadVision` has loaded one.
    private var vision: OpaquePointer?
    private let visionLoaded = OSAllocatedUnfairLock(initialState: false)
    /// The MTP draft model and its context, which reads this model's KV cache (`ctx_other`).
    private var drafter: Drafter?

    public let contextLength: Int
    /// False for hybrid and recurrent models (Qwen 3.5): their state can't be rolled back, so the
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
    /// Whether replies are drafted by an MTP model (`ModelOptions.draftModel` loaded and fits).
    public var hasDrafter: Bool { drafter != nil }
    /// About how many tokens an image takes (the projector is capped at this), for counting a
    /// prompt before its images are encoded.
    public static let imageTokens = 280

    private static let backend: Void = llama_backend_init()
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
        let loaded = llama_model_load_from_file(path, mp)
        #endif
        guard let model = loaded else {
            throw isCancelled?() == true ? LlamaError.cancelled : LlamaError.loadFailed(path)
        }
        guard let template = ChatTemplate(model: model) else {
            llama_model_free(model)
            throw LlamaError.unsupportedModel
        }

        var cp = llama_context_default_params()
        // Attention-only models can drop the end of their cache. Whether they can go back any
        // further depends on their sliding-window layers remembering more than the window.
        let attentionOnly = !llama_model_is_hybrid(model) && !llama_model_is_recurrent(model)
        let fullWindows = options.fullWindowCache ?? attentionOnly
        let canRewind = attentionOnly && (fullWindows || llama_model_n_swa(model) == 0)
        cp.n_ctx = options.contextLength
        cp.n_batch = UInt32(options.batchSize)
        cp.n_ubatch = UInt32(options.batchSize)
        // Logits are asked for one position when reading a prompt and for each verified token while
        // answering, never a whole batch: without this limit the context reserves a batch-sized
        // logits buffer (batch × vocabulary floats, 0.5 GB per 512 tokens on Gemma's 262k vocabulary).
        cp.n_outputs_max = UInt32(max(1, options.draftModel == nil ? 1 : options.draftTokens + 1))
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        if !options.f16Cache {
            cp.type_k = GGML_TYPE_Q8_0  // half the memory of f16 for a small quality cost
            cp.type_v = GGML_TYPE_Q8_0
        }
        // A model that can't rewind has no use for sliding-window layers remembering more than
        // their window: less cache and a slightly faster prefill.
        cp.swa_full = fullWindows
        let threads = Self.threadCount
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
        self.canRewind = canRewind
        self.threads = threads
        self.batchSize = options.batchSize
        if attentionOnly, let draftPath = options.draftModel {
            drafter = Drafter(path: draftPath, params: mp, target: model, targetContext: ctx, targetParams: cp,
                              maxTokens: options.draftTokens, minProbability: options.draftMinProbability)
        }
        let file = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        self.stateKey = [
            "v1", URL(fileURLWithPath: path).lastPathComponent, "\(file?.fileSize ?? 0)",
            "\(Int(file?.contentModificationDate?.timeIntervalSince1970 ?? 0))",
            "ctx\(llama_n_ctx(ctx))", options.f16Cache ? "f16" : "q8", canRewind ? "full" : "swa",
        ].joined(separator: "|")
    }

    deinit {
        if let vision { mtmd_free(vision) }
        drafter = nil  // it reads this context's cache, so it goes first
        llama_free(ctx)
        llama_model_free(model)
    }

    /// Streams the reply. Generations queue behind each other; each has its own stop flag, set when
    /// the reader stops iterating, so stopping one can never stop the next.
    ///
    /// `checkpoint` is a directory for this conversation's saved state. When the cache doesn't
    /// already hold the conversation, a matching state found there is loaded instead of reading
    /// the chat again, and the new state is saved there once the reply ends cleanly.
    ///
    /// When the system message declares web search (`ChatMessage.tools`), a call the model writes
    /// is answered with `search` (reported as `.searching` and `.searched`), its result added to
    /// the end of the cache, and the reply carries on: nothing is ever rewound for it.
    public func generate(
        _ messages: [ChatMessage], sampling: Sampling, thinking: Thinking = .off, maxTokens: Int = 2048,
        checkpoint: URL? = nil, search: (@Sendable (WebSearch) async -> WebSearch)? = nil
    ) -> AsyncThrowingStream<Generation, Error> {
        let stopped = OSAllocatedUnfairLock(initialState: false)
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in stopped.withLock { $0 = true } }
            queue.async {
                do {
                    let stats = try self.run(
                        messages, sampling: sampling, thinking: thinking, maxTokens: maxTokens, checkpoint: checkpoint,
                        search: search, isStopped: { stopped.withLock { $0 } }, emit: { continuation.yield($0) })
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
        search: (@Sendable (WebSearch) async -> WebSearch)?, isStopped: () -> Bool, emit: (Generation) -> Void
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
            // Append only. Hybrid models (Qwen 3.5's Gated DeltaNet layers) can't roll their state back,
            // so never rewinding is what makes multi-turn chat cheap on them.
            let tokens = try tokenize(template.renderContinuation(rest, thinking: thinking))
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
        var parser = template.makeParser(thinking: thinking)
        var utf8 = UTF8Assembler()
        var answer = ""
        var endedCleanly = false
        var ended = false
        // Tool calls: only where the system turn declared the tool. A call's tokens are collected
        // (never shown) until it closes; then it's answered before the next token is picked.
        let tools = messages.first?.declaresWebSearch == true
        var searches: [WebSearch] = []
        var call: [UInt8]?
        var closedCall: String?
        func send(_ text: String, marker: Bool, control: Bool = false) {
            switch parser.consume(text, marker: marker, control: control) {
            case .thinking(let t): emit(.thinking(t))
            case .text(let t):
                answer += t
                emit(.text(t))
            case nil: break
            }
        }
        /// Shows a token the model picked and counts it, or ends the reply at an end-of-generation
        /// token (which stays out of the cache: the next turn's continuation starts with it).
        func commit(_ token: llama_token) -> Bool {
            if llama_vocab_is_eog(vocab, token) {
                endedCleanly = String(decoding: piece(token, special: true), as: UTF8.self) == template.turnEnd
                ended = true
                return false
            }
            stats.generatedTokens += 1
            let attr = llama_vocab_get_attr(vocab, token).rawValue
            let control = attr & LLAMA_TOKEN_ATTR_CONTROL.rawValue != 0
            let marker = control || attr & LLAMA_TOKEN_ATTR_USER_DEFINED.rawValue != 0
            if tools {
                let raw = piece(token, special: true)
                if call != nil {
                    if marker, String(decoding: raw, as: UTF8.self) == template.toolCallEnd {
                        closedCall = String(decoding: call!, as: UTF8.self)
                        call = nil
                    } else {
                        call! += raw
                    }
                    return true
                }
                if marker, String(decoding: raw, as: UTF8.self) == template.toolCallStart {
                    if let rest = utf8.flush() { send(rest, marker: false) }
                    call = []
                    return true
                }
            }
            if marker {
                if let rest = utf8.flush() { send(rest, marker: false) }
                send(String(decoding: piece(token, special: true), as: UTF8.self), marker: true, control: control)
            } else if let text = utf8.append(piece(token, special: false)) {
                send(text, marker: false)
            }
            return true
        }
        // Each step processes the token just picked, plus any drafted after it, in one batch. The
        // model then picks from each position's logits in turn: while it picks what was drafted,
        // that token is already processed and the next position's pick is free. The first pick that
        // differs is the next step's token, and the drafts after it are removed from the cache.
        // With greedy decoding that's the reply one token at a time would give; with sampling,
        // every token is still sampled from the model's own distribution.
        var next = llama_sampler_sample(smpl, ctx, -1)
        var state = drafter?.targetState(ctx, -1) ?? []
        /// Answers the call that just closed (its last token is in the cache): runs the search,
        /// adds the result after it and picks the next token from there.
        func answerCall() throws {
            guard let text = closedCall else { return }
            closedCall = nil
            var result: WebSearch
            if let query = template.searchQuery(inCall: text) {
                // The search asked for (query and topic, no results yet). Every outcome keeps its
                // topic, so the call renders back as the model wrote it.
                let request = WebSearch(query: query, topic: template.searchTopic(inCall: text))
                func failed(_ reason: String) -> WebSearch { WebSearch(query: query, topic: request.topic, error: reason) }
                if searches.count >= Self.searchLimit {
                    result = failed("That's as many searches as one answer can run.")
                } else if let search {
                    emit(.searching(query))
                    result = Self.wait(isStopped: isStopped) { await search(request) } ?? failed("The search was stopped.")
                    result.topic = request.topic
                } else {
                    result = failed("Searching isn't available right now.")
                }
            } else {
                result = WebSearch(query: "", error: "The search couldn't be read: give the query as the query parameter.")
            }
            var tokens = try tokenize(template.renderToolResult(result, thinking: thinking))
            if cached.count + tokens.count > contextLength - Self.replyRoom / 2 {
                result = WebSearch(query: result.query, topic: result.topic, error: "The results were too long for this chat.")
                tokens = try tokenize(template.renderToolResult(result, thinking: thinking))
            }
            searches.append(result)
            emit(.searched(result))
            try feed(tokens, batch: batch, isStopped: { false }, emit: { _ in })
            stats.promptTokens += tokens.count
            parser = template.makeParserAfterToolResult(thinking: thinking)
            next = llama_sampler_sample(smpl, ctx, -1)
            if let drafter { state = drafter.targetState(ctx, -1) }
        }
        generation: while stats.generatedTokens < maxTokens, cached.count < contextLength, !isStopped() {
            guard commit(next) else { break }
            if closedCall != nil {
                // The call's closing token isn't in the cache yet: put it there, then the result.
                try feed([next], batch: batch, isStopped: { false }, emit: { _ in })
                try answerCall()
                continue
            }
            let room = min(contextLength - cached.count - 1, maxTokens - stats.generatedTokens)
            let drafts = drafter?.draft(after: next, at: cached.count, state: state, limit: room) ?? []
            stats.draftedTokens += drafts.count
            try verify([next] + drafts, batch: batch)
            cached.append(next)
            var i = 0
            while true {
                let picked = llama_sampler_sample(smpl, ctx, Int32(i))
                if i < drafts.count, picked == drafts[i] {
                    stats.acceptedDraftTokens += 1
                    guard stats.generatedTokens < maxTokens, !isStopped(), commit(picked) else { break generation }
                    cached.append(picked)
                    i += 1
                    if closedCall != nil { break }  // a drafted call closed: answer it below
                    continue
                }
                next = picked
                if let drafter { state = drafter.targetState(ctx, Int32(i)) }
                break
            }
            if i < drafts.count { _ = llama_memory_seq_rm(llama_get_memory(ctx), 0, llama_pos(cached.count), -1) }
            if closedCall != nil { try answerCall() }
            used.withLock { $0 = cached.count }
        }
        if drafter != nil {
            // An accepted draft the reply stopped at (end of turn, length, a stop) is still in the cache.
            _ = llama_memory_seq_rm(llama_get_memory(ctx), 0, llama_pos(cached.count), -1)
            used.withLock { $0 = cached.count }
        }
        if let rest = utf8.flush() { send(rest, marker: false) }
        stats.generateSeconds = Date().timeIntervalSince(start)
        if !ended {
            stats.stopReason = isStopped() ? .stopped : stats.generatedTokens >= maxTokens ? .maxTokens : .contextFull
        }
        if endedCleanly {
            transcript = (messages + [ChatMessage(role: .assistant, content: answer, searches: searches)], thinking)
            // Worth saving only if a later turn could continue it (not Gemma with thinking on).
            if template.canContinue(from: thinking, to: thinking, keepingThinking: !canRewind) { unsaved = checkpoint }
        }
        return stats
    }

    /// Searches one reply may run; a call past it is told so, and the model answers.
    public static let searchLimit = 3

    /// Runs `work` from `queue` (which waits on it), giving up when the reply is stopped.
    private static func wait<T: Sendable>(isStopped: () -> Bool, _ work: @escaping @Sendable () async -> T) -> T? {
        let result = OSAllocatedUnfairLock<T?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let task = Task {
            let value = await work()
            result.withLock { $0 = value }
            done.signal()
        }
        while done.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
            if isStopped() {
                task.cancel()
                return nil
            }
        }
        return result.withLock { $0 }
    }

    /// The messages after `base` if `messages` extends it in a way the cache can follow: same
    /// thinking setting, and ending with the user's turn. A model that can rewind only appends
    /// user turns (anything else is re-rendered and the shared prefix reused); one that can't also
    /// appends earlier replies as plain history, e.g. a stopped answer, since its only other
    /// option is reading everything again.
    private func continuation(
        of base: (messages: [ChatMessage], thinking: Thinking)?, to messages: [ChatMessage], thinking: Thinking
    ) -> [ChatMessage]? {
        guard let base, template.canContinue(from: base.thinking, to: thinking, keepingThinking: !canRewind),
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
            if canCut(to: keep), llama_memory_seq_rm(mem, 0, llama_pos(keep), -1) {
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

    /// Whether the cache can be cut back to its first `keep` tokens. Sliding-window layers must
    /// still hold the window before that point, and after a restore they don't: a saved state
    /// keeps only the last window of them, even from a full-size cache, and `llama_memory_seq_rm`
    /// succeeds all the same, leaving those layers with less to look at than they were trained on.
    private func canCut(to keep: Int) -> Bool {
        guard canRewind else { return false }
        let window = Int(llama_model_n_swa(model))
        guard window > 0 else { return true }
        return Int(llama_memory_seq_pos_min(llama_get_memory(ctx), 0)) <= max(0, keep - window)
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
            if canCut(to: keep), llama_memory_seq_rm(mem, 0, llama_pos(keep), -1) {
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
                    vision, ctx, span.chunk, llama_pos(cached.count), 0, Int32(batchSize), false, &past)
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
        if keep < cached.count, !(canCut(to: keep) && llama_memory_seq_rm(llama_get_memory(ctx), 0, llama_pos(keep), -1)) {
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
            let end = min(index + batchSize, tokens.count)
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
            if tokens.count > batchSize { emit(.reading(Double(index) / Double(tokens.count))) }
        }
    }

    /// Processes a generation step's tokens at the end of the cache with logits for each, without
    /// adding them to `cached`: the caller adds the ones the model keeps.
    private func verify(_ tokens: [llama_token], batch: OpaquePointer) throws {
        llama_batch_ext_clear(batch)
        for (i, token) in tokens.enumerated() {
            let idx = llama_batch_ext_add_token(batch, 0, token)
            guard idx >= 0 else { throw LlamaError.processFailed(idx) }
            var pos = llama_pos(cached.count + i)
            _ = llama_batch_ext_set_pos(batch, idx, &pos)
            _ = llama_batch_ext_set_output_logits(batch, idx, true)
        }
        let rc = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
        guard rc == 0 else { throw rc == 1 ? LlamaError.contextFull : LlamaError.processFailed(rc) }
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
        if s.presencePenalty != 0 {
            // After top-k, so it looks at a few candidates instead of the whole vocabulary. The
            // chain is new for each reply, so it sees the reply's tokens only.
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(
                llama_vocab_n_tokens(vocab), Int32(contextLength), 1, 0, s.presencePenalty))
        }
        if s.topP < 1 { llama_sampler_chain_add(chain, llama_sampler_init_top_p(s.topP, 1)) }
        if s.minP > 0 { llama_sampler_chain_add(chain, llama_sampler_init_min_p(s.minP, 1)) }
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

/// An MTP draft model (Gemma 4's assistant) and its context. It has no cache of its own: its
/// attention reads the target's (llama.cpp shares the KV cells through `ctx_other`), so it only ever
/// sees what the target has processed, and drafting leaves the target's cache untouched. Each draft
/// step takes the token before and a hidden state (the target's for the first step, its own after),
/// all at the position of the first drafted token, as llama.cpp's `draft-mtp` does for Gemma 4.
/// Used only on the target's queue.
private final class Drafter {
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let batch: OpaquePointer
    private let width: Int
    private let vocabSize: Int
    let maxTokens: Int
    /// A draft stops at a token the drafter is less sure of than this (llama.cpp's `p_min`).
    private let minProbability: Float

    init?(
        path: String, params: llama_model_params, target: OpaquePointer, targetContext: OpaquePointer,
        targetParams: llama_context_params, maxTokens: Int, minProbability: Float
    ) {
        self.minProbability = minProbability
        guard maxTokens > 0 else { return nil }
        var mp = params
        mp.progress_callback = nil
        mp.progress_callback_user_data = nil
        mp.lazy_mode = LLAMA_LAZY_MODE_OFF
        #if targetEnvironment(simulator)
        // CPU only, as for the target; its device list only lived for the target's load.
        var devices: [ggml_backend_dev_t?] = [ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU), nil]
        let loaded = devices.withUnsafeMutableBufferPointer { buf in
            mp.devices = buf.baseAddress
            return llama_model_load_from_file(path, mp)
        }
        #else
        mp.devices = nil
        let loaded = llama_model_load_from_file(path, mp)
        #endif
        guard let model = loaded else { return nil }
        let width = Int(llama_model_n_embd_out(model))
        guard llama_model_n_layer_nextn(model) > 0, width == Int(llama_model_n_embd_out(target)),
              llama_vocab_n_tokens(llama_model_get_vocab(model)) == llama_vocab_n_tokens(llama_model_get_vocab(target))
        else {
            llama_model_free(model)
            return nil
        }
        var cp = llama_context_default_params()
        cp.ctx_type = LLAMA_CONTEXT_TYPE_MTP
        cp.ctx_other = targetContext
        cp.n_ctx = llama_n_ctx(targetContext)
        cp.n_batch = 8
        cp.n_ubatch = 8
        cp.n_seq_max = 1
        cp.n_threads = targetParams.n_threads
        cp.n_threads_batch = targetParams.n_threads_batch
        cp.flash_attn_type = targetParams.flash_attn_type
        cp.type_k = targetParams.type_k  // the cells it reads are the target's
        cp.type_v = targetParams.type_v
        cp.swa_full = targetParams.swa_full
        cp.offload_kqv = targetParams.offload_kqv
        cp.op_offload = targetParams.op_offload
        guard let ctx = llama_init_from_model(model, cp) else {
            llama_model_free(model)
            return nil
        }
        self.model = model
        self.ctx = ctx
        self.batch = llama_batch_ext_init(ctx)!
        self.width = width
        self.vocabSize = Int(llama_vocab_n_tokens(llama_model_get_vocab(model)))
        self.maxTokens = maxTokens
        // The target hands over its last hidden state for each position it outputs logits for.
        llama_set_embeddings_nextn(targetContext, true, true)
        llama_set_embeddings_nextn(ctx, true, true)
    }

    deinit {
        llama_batch_ext_free(batch)
        llama_free(ctx)
        llama_model_free(model)
    }

    /// The target's hidden state at output `index` of its last batch: what the first draft step
    /// pairs with the token picked from that position's logits.
    func targetState(_ target: OpaquePointer, _ index: Int32) -> [Float] {
        guard let row = llama_get_embeddings_nextn_ith(target, index) else { return [] }
        return Array(UnsafeBufferPointer(start: row, count: width))
    }

    /// Up to `limit` (and `maxTokens`) tokens likely to follow `token`, which the target will
    /// process at `position`. Greedy: the drafter's most likely token at each step.
    func draft(after token: llama_token, at position: Int, state first: [Float], limit: Int) -> [llama_token] {
        guard first.count == width else { return [] }
        var out: [llama_token] = []
        var token = token
        var state = first
        var logits = [Float](repeating: 0, count: vocabSize)
        while out.count < min(limit, maxTokens) {
            llama_batch_ext_clear(batch)
            let idx = llama_batch_ext_add_token(batch, 0, token)
            guard idx >= 0 else { break }
            var pos = llama_pos(position)
            _ = llama_batch_ext_set_pos(batch, idx, &pos)
            _ = llama_batch_ext_set_output_logits(batch, idx, true)
            let rc = state.withUnsafeBufferPointer { h -> Int32 in
                guard llama_batch_ext_set_embd_state(batch, idx, llama_embd(data: h.baseAddress, n_rows: 1, n_embd: width)) else { return -1 }
                return llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
            }
            guard rc == 0, let raw = llama_get_logits_ith(ctx, idx), let h = llama_get_embeddings_nextn_ith(ctx, idx) else { break }
            // The most likely token and its probability (softmax of the logits).
            var best: Float = 0
            var bestIndex: vDSP_Length = 0
            vDSP_maxvi(raw, 1, &best, &bestIndex, vDSP_Length(vocabSize))
            var shift = -best
            vDSP_vsadd(raw, 1, &shift, &logits, 1, vDSP_Length(vocabSize))
            var n = Int32(vocabSize)
            vvexpf(&logits, logits, &n)
            var sum: Float = 0
            vDSP_sve(logits, 1, &sum, vDSP_Length(vocabSize))
            guard 1 / sum >= minProbability else { break }
            token = llama_token(bestIndex)
            out.append(token)
            state = Array(UnsafeBufferPointer(start: h, count: width))
        }
        return out
    }
}
#else
/// Mac Catalyst: llama.cpp isn't linked there (a Mac serves or uses a Mac's model, never one of
/// its own), so this is a model that can't be loaded.
public final class LlamaModel: @unchecked Sendable {
    public let contextLength = 0
    public let canRewind = false
    public let stateKey = ""
    public var tokensInContext: Int { 0 }
    public var promptLimit: Int { 0 }
    public var sizeBytes: UInt64 { 0 }
    public var templateName: String { "" }
    public var hasVision: Bool { false }
    public var hasDrafter: Bool { false }
    public static let imageTokens = 280
    public static let searchLimit = 3

    public init(
        path: String, options: ModelOptions = ModelOptions(),
        progress: (@Sendable (Float) -> Void)? = nil, isCancelled: (@Sendable () -> Bool)? = nil
    ) throws {
        throw LlamaError.loadFailed(path)
    }
    public func generate(
        _ messages: [ChatMessage], sampling: Sampling, thinking: Thinking = .off, maxTokens: Int = 2048,
        checkpoint: URL? = nil, search: (@Sendable (WebSearch) async -> WebSearch)? = nil
    ) -> AsyncThrowingStream<Generation, Error> {
        AsyncThrowingStream { $0.finish(throwing: LlamaError.cancelled) }
    }
    public func loadVision(projector path: String) async throws { throw LlamaError.visionFailed }
    public func prepare(_ messages: [ChatMessage], thinking: Thinking, checkpoint: URL?) async {}
    public func adoptLegacyState(from legacy: URL, into directory: URL) {}
    public func flush() async {}
    public func countTokens(_ messages: [ChatMessage], thinking: Thinking = .off) async -> Int { 0 }
}
#endif
