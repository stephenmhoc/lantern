import CoreGraphics
import Foundation
import ImageIO
import LlamaKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple Intelligence's on-device model can answer here, in a word or two for the picker
/// and the Models page. Nothing here waits or needs the network: it's the system's own flag.
nonisolated enum AppleStatus: Equatable, Sendable {
    case available
    /// This iPhone or iPad can't run Apple Intelligence.
    case notEligible
    /// It can, but Apple Intelligence is off in Settings.
    case off
    /// It's on, but the model is still downloading or getting ready.
    case notReady
    /// Before iOS 26, which has no Foundation Models framework.
    case needsNewerSystem

    var isAvailable: Bool { self == .available }

    /// "Built in", "Turn on in Settings"…
    var short: String {
        switch self {
        case .available: "Built in"
        case .notEligible: "Not on this device"
        case .off: "Turn on in Settings"
        case .notReady: "Getting ready"
        case .needsNewerSystem: "Needs iOS 26"
        }
    }

    /// One sentence for the detail page and for a reply that couldn't start.
    var explanation: String {
        switch self {
        case .available: "Apple Intelligence is on and its model is ready."
        case .notEligible: "This device can't run Apple Intelligence."
        case .off: "Apple Intelligence is off. Turn it on in Settings > Apple Intelligence & Siri."
        case .notReady: "Apple Intelligence is still getting its model ready. It downloads on its own; try again later."
        case .needsNewerSystem: "Apple Intelligence's model needs iOS 26 or later."
        }
    }

    static var current: AppleStatus {
        #if DEBUG
        // `-appleStatus off|notEligible|notReady`: shows that status, for screenshots.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-appleStatus"), args.indices.contains(i + 1) {
            switch args[i + 1] {
            case "off": return .off
            case "notEligible": return .notEligible
            case "notReady": return .notReady
            default: break
            }
        }
        #endif
        #if canImport(FoundationModels)
        guard #available(iOS 26, *) else { return .needsNewerSystem }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .notEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .off
        case .unavailable(.modelNotReady): return .notReady
        case .unavailable: return .notReady  // a reason added later
        }
        #else
        return .needsNewerSystem
        #endif
    }
}

nonisolated enum AppleError: LocalizedError {
    case unavailable(AppleStatus)
    case contextFull
    case guardrail
    case refusal
    case language
    case busy
    case noVision
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let status): status.explanation
        case .contextFull: "This chat is too long for Apple Intelligence, which holds less of a chat than the other models."
        case .guardrail: "Apple Intelligence's content checks stopped this answer. Try rephrasing it, or ask another model."
        case .refusal: "Apple Intelligence declined to answer this. Try rephrasing it, or ask another model."
        case .language: "Apple Intelligence doesn't answer in this language yet. Try another model."
        case .busy: "Apple Intelligence is limiting requests right now. Try again in a moment."
        case .noVision: "Apple Intelligence can't see images on this device. Gemma 4 E2B and E4B can, with Image reading."
        case .failed(let message): message
        }
    }

    var kind: ReplyErrorKind {
        switch self {
        case .unavailable: .notDownloaded  // offers the Models page, which says what to do
        case .contextFull: .contextFull
        default: .other
        }
    }
}

/// Apple Intelligence's on-device model through the Foundation Models framework (iOS 26+). It runs
/// in a system process, so there's nothing to download or load and no memory of Lantern's to free;
/// its context is small (about 4,000 tokens).
///
/// A session keeps its own transcript, so a follow-up in the same chat continues the session that
/// wrote the last answer. Anything else (reopening a chat, Retry, an edit, a stopped or failed
/// reply, dropped turns) builds a fresh session from the stored history: each `ChatMessage` is
/// rendered by `StoredMessage.chatMessage`, the same text every model gets.
final class AppleLink {
    /// One chat's session and the history it holds (system prompt first, then every turn).
    private struct Cached {
        var held: [ChatMessage]
        var session: AnyObject  // LanguageModelSession, which only exists on iOS 26+
        /// Where its web search tool reports, if it has one.
        var searches: SearchSink?
        var used: Date
    }

    /// Results a search here keeps: the context is about 4,000 tokens, half of Gemma's.
    nonisolated static let searchResults = 3
    nonisolated static let searchExcerpt = 500

    private var sessions: [String: Cached] = [:]
    /// A few open chats (windows) keep theirs; sessions are small, the model is the system's.
    private static let kept = 4

    var status: AppleStatus { AppleStatus.current }

    /// The most a chat holds, in tokens: the model's context (4,096 until iOS 26.4 reported it).
    var contextSize: Int {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) { return SystemLanguageModel.default.contextSize }
        #endif
        return 4096
    }

    /// iOS 27's model may take images (`.vision`); iOS 26's can't.
    var seesImages: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 27, *), status.isAvailable { return SystemLanguageModel.default.capabilities.contains(.vision) }
        #endif
        return false
    }

    func forget(_ key: String) { sessions[key] = nil }

    /// Builds the chat's session ahead of the question and lets the system load the model.
    func prewarm(_ history: [ChatMessage], key: String) {
        #if canImport(FoundationModels)
        guard #available(iOS 26, *), status.isAvailable, !history.isEmpty else { return }
        let session = session(for: history, key: key, rebuildFrom: history)
        session.prewarm()
        #endif
    }

    /// Streams the answer to the last message of the first history in `attempts`. When the chat
    /// doesn't fit and there are more attempts (shorter histories, oldest turns dropped), the next is
    /// tried and `onTrim` gets its start. Cancelling the consumer stops the model.
    func stream(
        attempts: [(start: Int, history: [ChatMessage])], key: String, onTrim: @escaping (Int) -> Void
    ) -> AsyncThrowingStream<Generation, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await self.run(attempts: attempts, key: key, onTrim: onTrim, into: continuation)
                    continuation.finish()
                } catch {
                    self.sessions[key] = nil  // its transcript may hold half a turn
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        attempts: [(start: Int, history: [ChatMessage])], key: String, onTrim: (Int) -> Void,
        into continuation: AsyncThrowingStream<Generation, Error>.Continuation
    ) async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26, *) else { throw AppleError.unavailable(.needsNewerSystem) }
        guard status.isAvailable else { throw AppleError.unavailable(status) }
        for (n, attempt) in attempts.enumerated() {
            guard let question = attempt.history.last, question.role == .user else { throw AppleError.failed("Nothing to answer.") }
            if question.hasImages, !seesImages { throw AppleError.noVision }
            // Counted first where the system can (iOS 26.4+): too long a prompt doesn't always come
            // back as `contextSizeExceeded` (the simulator returns an untyped model-manager error).
            if await !fits(attempt.history) {
                if n + 1 < attempts.count { continue }
                throw AppleError.contextFull
            }
            if n > 0 { onTrim(attempt.start) }
            let session = session(for: Array(attempt.history.dropLast()), key: key, rebuildFrom: attempt.history)
            // The session's tool reports to this reply: what it searched goes on the answer.
            let sink = sessions[key]?.searches
            sink?.start(continuation)
            defer { sink?.stop() }
            var text = ""
            var stats = GenerationStats()
            let started = Date()
            var firstAt: Date?
            do {
                let stream = session.streamResponse(to: Self.prompt(question, seesImages: seesImages))
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    let now = snapshot.content
                    if firstAt == nil, !now.isEmpty { firstAt = Date() }
                    // Snapshots are the whole answer so far: send what's new.
                    if now.count > text.count, now.hasPrefix(text) {
                        continuation.yield(.text(String(now.dropFirst(text.count))))
                    }
                    text = now
                    if #available(iOS 27, *) {
                        stats.promptTokens = snapshot.usage.input.totalTokenCount
                        stats.reusedTokens = snapshot.usage.input.cachedTokenCount
                        stats.generatedTokens = snapshot.usage.output.totalTokenCount
                    }
                }
            } catch let error where Self.isContextFull(error) {
                sessions[key] = nil
                if text.isEmpty {
                    if n + 1 < attempts.count { continue }  // drop more and try again
                    throw AppleError.contextFull
                }
                stats.stopReason = .contextFull  // the answer itself ran out of room: keep what came
            } catch is CancellationError {
                sessions[key] = nil
                throw CancellationError()
            } catch {
                throw Self.translate(error)
            }
            let end = Date()
            stats.promptSeconds = (firstAt ?? end).timeIntervalSince(started)
            // Snapshots can come in a few bursts (the simulator delivers most of an answer at once),
            // so the time after the first one can be next to nothing: then the whole wait counts,
            // which understates the speed a little (reading the chat is in it) rather than inflating it.
            let streamed = firstAt.map { end.timeIntervalSince($0) } ?? 0
            stats.generateSeconds = streamed >= 0.25 ? streamed : end.timeIntervalSince(started)
            if stats.stopReason == .end {
                sessions[key]?.held = attempt.history + [ChatMessage(role: .assistant, content: text, searches: sink?.searches ?? [])]
            }
            continuation.yield(.done(stats))
            return
        }
        throw AppleError.contextFull
        #else
        throw AppleError.unavailable(.needsNewerSystem)
        #endif
    }

    /// Model test for the Models page: a one-word answer through a throwaway session.
    func test() async throws -> GenerationStats {
        var result = GenerationStats()
        let question = [ChatMessage(role: .system, content: "Answer briefly."), ChatMessage(role: .user, content: "Reply with one word: ready.")]
        let key = "test-\(UUID().uuidString)"
        defer { forget(key) }
        for try await event in stream(attempts: [(0, question)], key: key, onTrim: { _ in }) {
            if case .done(let s) = event { result = s }
        }
        return result
    }

    #if canImport(FoundationModels)
    /// Whether the history leaves room for an answer: the prompt may take up to three quarters of
    /// the context, as `fittingStart` keeps for llama.cpp. True where tokens can't be counted.
    @available(iOS 26, *)
    private func fits(_ history: [ChatMessage]) async -> Bool {
        guard #available(iOS 26.4, *),
              let tokens = try? await SystemLanguageModel.default.tokenCount(for: Self.transcript(history)) else { return true }
        return tokens <= contextSize * 3 / 4
    }

    /// The chat's session if it holds exactly `held`, else a new one holding it.
    @available(iOS 26, *)
    private func session(for held: [ChatMessage], key: String, rebuildFrom history: [ChatMessage]) -> LanguageModelSession {
        if let cached = sessions[key], cached.held == held, let session = cached.session as? LanguageModelSession, !session.isResponding {
            sessions[key]?.used = .now
            return session
        }
        // Search is declared with the system prompt, as for Gemma and Qwen, so a change rebuilds it.
        let sink = held.first?.declaresWebSearch == true ? SearchSink() : nil
        let tools: [any Tool] = sink.map { [WebSearchTool(sink: $0)] } ?? []
        let session = LanguageModelSession(model: .default, tools: tools, transcript: Self.transcript(held))
        sessions[key] = Cached(held: held, session: session, searches: sink, used: .now)
        if sessions.count > Self.kept, let oldest = sessions.min(by: { $0.value.used < $1.value.used })?.key {
            sessions[oldest] = nil
        }
        return session
    }

    /// The system prompt as instructions (with the search tool when it's declared), then the turns
    /// as prompts and responses, each answer's searches before it as the calls and what they found.
    @available(iOS 26, *)
    private static func transcript(_ messages: [ChatMessage]) -> Transcript {
        var entries: [Transcript.Entry] = []
        var calls = 0
        for m in messages {
            let text = Transcript.Segment.text(Transcript.TextSegment(content: m.content))
            switch m.role {
            case .system:
                let tools = m.declaresWebSearch ? [Transcript.ToolDefinition(tool: WebSearchTool(sink: SearchSink()))] : []
                entries.append(.instructions(Transcript.Instructions(segments: [text], toolDefinitions: tools)))
            case .user:
                entries.append(.prompt(Transcript.Prompt(segments: imageSegments(m) + [text])))
            case .assistant:
                for search in m.searches ?? [] {
                    calls += 1
                    let id = "search-\(calls)"
                    let call = Transcript.ToolCall(
                        id: id, toolName: WebSearch.toolName, arguments: GeneratedContent(properties: ["query": search.query]))
                    entries.append(.toolCalls(Transcript.ToolCalls([call])))
                    entries.append(.toolOutput(Transcript.ToolOutput(
                        id: id, toolName: WebSearch.toolName,
                        segments: [.text(Transcript.TextSegment(content: search.modelText))])))
                }
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [text])))
            }
        }
        return Transcript(entries: entries)
    }

    /// An earlier question's images, for a model that can see; none otherwise (its text still goes).
    @available(iOS 26, *)
    private static func imageSegments(_ m: ChatMessage) -> [Transcript.Segment] {
        guard #available(iOS 27, *), SystemLanguageModel.default.capabilities.contains(.vision) else { return [] }
        return (m.images ?? []).compactMap(cgImage).map {
            .attachment(Transcript.AttachmentSegment(content: .image(Transcript.ImageAttachment($0))))
        }
    }

    /// The question: its images first (as Gemma sees them), then its text.
    @available(iOS 26, *)
    private static func prompt(_ m: ChatMessage, seesImages: Bool) -> Prompt {
        if #available(iOS 27, *), seesImages {
            let images = (m.images ?? []).compactMap(cgImage).map { FoundationModels.Attachment($0) }
            if !images.isEmpty { return Prompt { images; m.content } }
        }
        return Prompt(m.content)
    }

    private static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @available(iOS 26, *)
    private static func isContextFull(_ error: Error) -> Bool {
        if #available(iOS 27, *), let e = error as? LanguageModelError, case .contextSizeExceeded = e { return true }
        if let e = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = e { return true }
        return false
    }

    /// The framework's errors as short sentences of Lantern's own.
    @available(iOS 26, *)
    private static func translate(_ error: Error) -> Error {
        if #available(iOS 27, *), let e = error as? LanguageModelError {
            switch e {
            case .guardrailViolation: return AppleError.guardrail
            case .refusal: return AppleError.refusal
            case .unsupportedLanguageOrLocale: return AppleError.language
            case .rateLimited: return AppleError.busy
            case .unsupportedCapability, .unsupportedTranscriptContent: return AppleError.noVision
            default: return AppleError.failed(e.localizedDescription)
            }
        }
        if #available(iOS 27, *), let e = error as? SystemLanguageModel.Error, case .assetsUnavailable = e {
            return AppleError.unavailable(.notReady)
        }
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .guardrailViolation: return AppleError.guardrail
            case .refusal: return AppleError.refusal
            case .unsupportedLanguageOrLocale: return AppleError.language
            case .rateLimited, .concurrentRequests: return AppleError.busy
            case .assetsUnavailable: return AppleError.unavailable(.notReady)
            default: return AppleError.failed(e.localizedDescription)
            }
        }
        return error
    }
    #endif
}

/// Hands a session's search events to the reply being written. A session (and its tool) can write
/// many replies, so each one points the sink at its own stream and collects its own searches.
nonisolated final class SearchSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Generation, Error>.Continuation?
    private var collected: [WebSearch] = []

    var searches: [WebSearch] { lock.withLock { collected } }

    func start(_ continuation: AsyncThrowingStream<Generation, Error>.Continuation) {
        lock.withLock { self.continuation = continuation; collected = [] }
    }

    func stop() { lock.withLock { continuation = nil } }

    /// Runs a search for the reply, unless it has already run as many as one may.
    func search(_ query: String) async -> WebSearch {
        let (sink, count) = lock.withLock { (continuation, collected.count) }
        let result: WebSearch
        if count >= LlamaModel.searchLimit {
            result = WebSearch(query: query, error: "That's as many searches as one answer can run.")
        } else {
            sink?.yield(.searching(query))
            result = await WebSearcher.search(query, results: AppleLink.searchResults, excerpt: AppleLink.searchExcerpt)
        }
        lock.withLock { collected.append(result) }
        sink?.yield(.searched(result))
        return result
    }
}

#if canImport(FoundationModels)
/// The web search tool, as Gemma and Qwen are given it: the same name, description and query, and
/// the model reads the same text back (`WebSearch.modelText`).
@available(iOS 26, *)
nonisolated struct WebSearchTool: Tool {
    let sink: SearchSink
    let name = WebSearch.toolName
    let description = WebSearch.toolDescription

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "What to search for, as you'd type it into a search engine.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        await sink.search(arguments.query).modelText
    }
}
#endif
