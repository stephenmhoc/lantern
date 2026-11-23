import Foundation
import LlamaKit
import Observation
import SwiftData
import UIKit

/// Runs the one generation that can happen at a time, in whichever mode a chat uses. Only one
/// on-device model is loaded at a time, since two would crowd each other out of memory.
@Observable
final class Engine {
    let store = ModelStore.shared
    let mac = MacLink()

    /// The chat that's answering. Every other chat's Send is disabled until it's done.
    private(set) var running: PersistentIdentifier?
    /// The reply being written. Read by the chat screen on a timer, not observed per token.
    private(set) var live: LiveReply?
    private(set) var loadedModel: CatalogModel?
    /// Set while a model self-test runs, which also blocks chats.
    private(set) var testing: CatalogModel?
    var isBusy: Bool { running != nil || testing != nil }

    @ObservationIgnored private var llama: LlamaModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var idleUnload: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func model(for mode: Mode) -> CatalogModel? {
        CatalogModel.preferred(for: mode, downloaded: store.downloaded)
    }

    // MARK: - Chats

    func send(_ text: String, in conversation: Conversation) {
        guard !isBusy else { return }
        if conversation.messages.isEmpty { conversation.title = String(text.prefix(60)) }
        conversation.messages.append(StoredMessage(isUser: true, content: text))
        generate(in: conversation)
    }

    /// Replaces the last reply with a new one, optionally from another mode.
    func retry(in conversation: Conversation, mode: Mode) {
        guard !isBusy, conversation.messages.last?.isUser == false else { return }
        conversation.messages.removeLast()
        conversation.mode = mode
        generate(in: conversation)
    }

    /// Stops the running reply and starts it again in `mode` (e.g. Smart is too slow: use Fast).
    func restart(in conversation: Conversation, mode: Mode) {
        let previous = task
        previous?.cancel()
        Task {
            await previous?.value
            retry(in: conversation, mode: mode)
        }
    }

    func stop() { task?.cancel() }

    private func generate(in conversation: Conversation) {
        let reply = StoredMessage(isUser: false, finished: false)
        conversation.messages.append(reply)
        conversation.updated = .now
        try? conversation.modelContext?.save()

        let mode = conversation.mode
        let thinking = conversation.thinking
        let history = [ChatMessage(role: .system, content: Self.systemPrompt())]
            + conversation.history(before: conversation.messages.count - 1)
        let live = LiveReply(id: reply.id, mode: mode)
        self.live = live
        running = conversation.persistentModelID
        idleUnload?.cancel()
        UIApplication.shared.isIdleTimerDisabled = true  // a slow answer shouldn't lock the screen

        task = Task {
            var stats: GenerationStats?
            var failure: String?
            var lastSave = Date()
            do {
                let stream: AsyncThrowingStream<Generation, Error>
                if mode == .mac {
                    live.phase = .waiting
                    stream = try await mac.stream(history, thinking: thinking)
                } else {
                    guard let model = model(for: mode), store.states[model.id] == .ready else {
                        throw EngineError.notDownloaded(mode)
                    }
                    let llama = try await load(model, live: live)
                    try Task.checkCancellation()
                    live.phase = .waiting
                    stream = llama.generate(history, sampling: model.sampling, thinking: thinking)
                }
                for try await event in stream {
                    switch event {
                    case .reading(let p): live.phase = .reading(p)
                    case .thinking(let t): live.append(thinking: t)
                    case .text(let t): live.append(text: t)
                    case .done(let s): stats = s
                    }
                    if Date().timeIntervalSince(lastSave) > 5 {  // so a crash keeps most of the answer
                        write(live, to: conversation, finished: false)
                        lastSave = .now
                    }
                }
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            finish(live, in: conversation, stats: stats, error: failure)
        }
    }

    private func finish(_ live: LiveReply, in conversation: Conversation, stats: GenerationStats?, error: String?) {
        var parts = [live.mode == .mac ? "Mac · \(mac.modelName)" : loadedModel?.name ?? live.mode.title]
        if let stats, stats.generatedTokens > 0 { parts.append(String(format: "%.1f tok/s", stats.tokensPerSecond)) }
        if stats == nil && error == nil { parts.insert(live.stopNote ?? "Stopped", at: 0) }
        write(live, to: conversation, finished: true) {
            $0.footnote = parts.joined(separator: " · ")
            $0.error = error
        }
        if stats != nil, Date().timeIntervalSince(live.started) > 5 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)  // you may have put it down
        }
        self.live = nil
        running = nil
        task = nil
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
        scheduleIdleUnload()
    }

    /// Copies the live reply into the stored message, unless the chat was deleted meanwhile.
    private func write(
        _ live: LiveReply, to conversation: Conversation, finished: Bool, extra: (inout StoredMessage) -> Void = { _ in }
    ) {
        guard conversation.modelContext != nil, !conversation.isDeleted,
              let i = conversation.index(of: live.id) else { return }
        conversation.messages[i].content = live.text
        conversation.messages[i].thinking = live.thinking
        conversation.messages[i].finished = finished
        extra(&conversation.messages[i])
        conversation.updated = .now
        try? conversation.modelContext?.save()
    }

    static func systemPrompt(now: Date = .now) -> String {
        """
        You are Lantern, a helpful assistant running privately on the user's own device. Today is \
        \(now.formatted(date: .complete, time: .omitted)). Answer clearly and concisely, and use lists \
        or numbered steps when they make an answer easier to follow.
        """
    }

    // MARK: - Leaving the app

    /// iOS doesn't allow GPU work in the background, so an on-device reply stops when you leave.
    /// A reply from the Mac gets the few seconds iOS allows to finish.
    func didEnterBackground() {
        guard let live else { return }
        if live.mode.isOnDevice {
            live.stopNote = "Stopped when you left Lantern"
            stop()
        } else {
            backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                self?.live?.stopNote = "Stopped when you left Lantern"
                self?.stop()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Models

    func unload() {
        guard !isBusy else { return }
        llama = nil
        loadedModel = nil
    }

    /// Frees the model's memory after a while unused. Reloading takes a few seconds.
    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        idleUnload = Task {
            try? await Task.sleep(for: .seconds(300))
            if !Task.isCancelled { unload() }
        }
    }

    private func load(_ model: CatalogModel, live: LiveReply?) async throws -> LlamaModel {
        if let llama, loadedModel == model { return llama }
        llama = nil  // free the old model before mapping the new one
        loadedModel = nil
        live?.phase = .loading(0)
        let path = store.url(for: model).path
        let lazy = model.lazyExperts
        let report: @Sendable (Float) -> Void = { progress in
            Task { @MainActor in live?.phase = .loading(Double(progress)) }
        }
        let loaded = try await Task.detached(priority: .userInitiated) {
            try LlamaModel(path: path, lazyExperts: lazy, progress: report)
        }.value
        llama = loaded
        loadedModel = model
        return loaded
    }

    /// Loads a model and asks for a one-word answer: proof it works on this device, and its speed.
    func test(_ model: CatalogModel) async throws -> GenerationStats {
        guard !isBusy else { throw EngineError.busy }
        testing = model
        defer {
            testing = nil
            scheduleIdleUnload()
        }
        let llama = try await load(model, live: nil)
        var result = GenerationStats()
        let question = [ChatMessage(role: .user, content: "Reply with one word: ready.")]
        for try await event in llama.generate(question, sampling: model.sampling, maxTokens: 400) {
            if case .done(let s) = event { result = s }
        }
        return result
    }
}

/// The reply being written. Plain (not observed): the chat screen polls `revision` a few times a
/// second, so tokens arriving at 150 a second don't each cause a UI update.
final class LiveReply {
    enum Phase: Equatable {
        case loading(Double), waiting, reading(Double), thinking, answering
    }

    let id: UUID
    let mode: Mode
    let started = Date()
    var phase: Phase = .waiting { didSet { revision += 1 } }
    private(set) var thinking = ""
    private(set) var text = ""
    private(set) var revision = 0
    /// Why it stopped, if it was stopped for the user rather than by them.
    var stopNote: String?

    init(id: UUID, mode: Mode) {
        self.id = id
        self.mode = mode
    }

    func append(thinking t: String) {
        thinking += t
        phase = .thinking
    }

    func append(text t: String) {
        text += t
        phase = .answering
    }

    /// One line for the reply while it's under way, e.g. "Thinking · 12 s".
    var status: String? {
        let seconds = Int(Date().timeIntervalSince(started))
        switch phase {
        case .loading(let p): return "Loading model \(Int(p * 100))%"
        case .waiting: return mode == .mac ? "Asking the Mac…" : "Reading your question…"
        case .reading(let p): return "Reading the chat \(Int(p * 100))%"
        case .thinking: return "Thinking · \(seconds) s"
        case .answering: return nil
        }
    }
}

nonisolated enum EngineError: LocalizedError {
    case notDownloaded(Mode), busy
    var errorDescription: String? {
        switch self {
        case .notDownloaded(let mode): "There's no \(mode.title) model on this device yet. Get one in Readiness."
        case .busy: "Lantern is answering. Try again when it's done."
        }
    }
}
