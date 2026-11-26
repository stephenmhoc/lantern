import UIKit
import Foundation
import LlamaKit
import Observation
import os
import SwiftData

/// Runs the one generation that can happen at a time: on this device's model (`store.model`)
/// or on the Mac.
@Observable
final class Engine {
    let store = ModelStore.shared
    let mac = MacLink()
    /// The chat that's answering. Every other chat's Send is disabled until it's done.
    private(set) var running: PersistentIdentifier?
    /// The reply being written. Read by the chat screen on a timer, not observed per token.
    private(set) var live: LiveReply?
    var isBusy: Bool { running != nil }

    @ObservationIgnored private var llama: LlamaModel?
    /// Which model `llama` is: the store's model changes when a better one finishes downloading.
    @ObservationIgnored private var loadedID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingLoad: PendingLoad?
    @ObservationIgnored private var prepared: Conversation?
    @ObservationIgnored private var prepareCount = 0
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        store.modelWillChange = { [weak self] in self?.unload() }
        // The model's cache and buffers are the app's largest dirty memory, and what's in them is
        // saved: under memory pressure, give them back rather than be killed.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unload() }
        }
    }

    // MARK: - Chats

    func send(_ text: String, attachments: [Attachment] = [], in conversation: Conversation) {
        guard !isBusy, !text.isEmpty || !attachments.isEmpty else { return }
        if conversation.messages.isEmpty { conversation.title = ChatTitler.provisional(text: text, attachments: attachments) }
        _ = frozenSystemPrompt(of: conversation)  // so the date note compares with the chat's own date
        var message = StoredMessage(isUser: true, content: text)
        message.attachments = attachments.isEmpty ? nil : attachments
        message.dateNote = conversation.dateNote()
        conversation.messages.append(message)
        generate(in: conversation)
    }

    /// Replaces the last reply with a new one. The answer it replaces (and its own earlier
    /// versions) are kept as the new one's other versions.
    func retry(in conversation: Conversation) {
        guard !isBusy, let old = conversation.messages.last, !old.isUser else { return }
        let kept = old.allVersions.list.filter { !$0.content.isEmpty }
        conversation.messages.removeLast()
        generate(in: conversation, versions: kept)
    }

    // MARK: - Compare (see CompareView)

    /// The comparison running now, if any: its id, which reply, and the model still to answer.
    /// Set by `compare` just before B starts (`running` is set in the same turn); cleared in
    /// `finish` when B ends however it ends (answered, failed, stopped, chat deleted), after B's
    /// metrics are stamped and the chat is back on A's model. `next` is B's model while it runs.
    private(set) var comparing: (id: UUID, conversation: PersistentIdentifier, next: ModelChoice?)?
    /// The live reply that is B, and the model and thinking to put the chat back on if B has
    /// nothing to show (A's).
    @ObservationIgnored private var comparison: (reply: UUID, mode: Mode, macModel: String, thinking: Thinking)?

    /// Answers the last question again with `other` and keeps both answers as a pair (the current
    /// answer is A, the new one B), the current answer stays as a version like Retry.
    ///
    /// Only B runs, through Retry's path, with the chat switched to `other`. The
    /// chat then continues with the model of the answer it shows (B, the newest), so the next
    /// question goes to the model that wrote the history it continues and can reuse its cache.
    /// If B produced nothing (failed or stopped empty) the chat goes back to A's model.
    /// `continueWith` is how the user picks an answer and its model together.
    ///
    /// `thinking`: whether B thinks (nil: as the chat does now). B may be A's own model when the
    /// thinking differs, to see what thinking buys on the same question.
    func compare(in conversation: Conversation, with other: ModelChoice, thinking: Thinking? = nil) {
        guard !isBusy, let last = conversation.messages.indices.last else { return }
        let reply = conversation.messages[last]
        guard !reply.isUser, reply.finished, reply.error == nil, !reply.content.isEmpty else { return }
        // An answer from before replies recorded their model: taken as the chat's.
        var a = reply.metrics ?? ReplyMetrics(
            modeRaw: conversation.answeringMode.rawValue,
            macModel: conversation.answeringMode == .mac ? conversation.resolvedMacModel : nil,
            modelTitle: conversation.modelTitle)
        let otherMac = other.mode == .mac ? other.macModel ?? conversation.resolvedMacModel : nil
        let bThinking = thinking ?? conversation.thinking
        // The same model only with the other thinking (an answer from before metrics: the chat's
        // setting). Told apart by name, so an answer another device's model wrote can be compared
        // with this device's.
        let sameModel = a.modelTitle == (otherMac.map(MacLink.displayName) ?? store.model.name)
        let aThinks = a.thinking ?? (conversation.thinking != .off)
        guard !sameModel || aThinks != (bThinking != .off) else { return }
        // A was already one side of an earlier comparison: that pair is undone rather than left
        // with one side, so its partner is an ordinary answer again (no compareID, no vote).
        if let earlier = a.compareID {
            let (list, current) = reply.allVersions
            for v in list.indices where v != current && list[v].metrics?.compareID == earlier {
                conversation.messages[last].updateMetrics(ofVersion: v) { $0?.compareID = nil; $0?.preferred = nil }
            }
        }
        let id = UUID()
        a.compareID = id
        a.preferred = nil
        conversation.messages[last].metrics = a
        let back = (mode: conversation.mode, macModel: conversation.macModel, thinking: conversation.thinking)
        comparing = (id, conversation.persistentModelID, other)
        conversation.thinking = bThinking
        conversation.mode = other.mode.current
        if let otherMac { conversation.macModel = otherMac }
        retry(in: conversation)
        guard let live, running == conversation.persistentModelID else {  // didn't start
            comparing = nil
            (conversation.mode, conversation.macModel, conversation.thinking) = back
            return
        }
        comparison = (live.id, back.mode, back.macModel, back.thinking)
    }

    /// Makes answer `index` of the last reply the one shown and switches the chat to its model.
    /// An answer without metrics (from before they existed) leaves the model as it is.
    func continueWith(in conversation: Conversation, version index: Int) {
        guard running != conversation.persistentModelID, let last = conversation.messages.indices.last,
              !conversation.messages[last].isUser,
              conversation.messages[last].allVersions.list.indices.contains(index) else { return }
        conversation.messages[last].showVersion(index)
        if let m = conversation.messages[last].metrics, let mode = Mode(rawValue: m.modeRaw)?.current {
            conversation.mode = mode
            if mode == .mac, let macModel = m.macModel, !macModel.isEmpty { conversation.macModel = macModel }
            // And its thinking, so comparing thinking on and off can be continued either way.
            if let thought = m.thinking { conversation.thinking = thought ? .high : .off }
        }
        try? conversation.modelContext?.save()
        // Load its model and restore its saved state (kept per model) before the next question.
        prepare(conversation)
    }

    /// Stops the reply, including while its model is still loading.
    func stop() { task?.cancel() }

    private func generate(in conversation: Conversation, trim: Bool = false, versions: [ReplyVersion] = []) {
        var reply = StoredMessage(isUser: false, finished: false)
        reply.versions = versions.isEmpty ? nil : versions
        conversation.messages.append(reply)
        conversation.lastActive = .now
        try? conversation.modelContext?.save()

        let mode = conversation.answeringMode
        let thinking = conversation.thinking
        let system = systemMessage(of: conversation, mode: mode)
        var history = [system] + conversation.history(before: conversation.messages.count - 1)
        let macModel = conversation.resolvedMacModel
        if mode == .mac, conversation.macModel.isEmpty, !macModel.isEmpty { conversation.macModel = macModel }
        let live = LiveReply(id: reply.id, mode: mode)
        live.modelTitle = store.model.name
        live.macModel = macModel
        live.thinkingAsked = thinking != .off
        self.live = live
        running = conversation.persistentModelID
        UIApplication.shared.isIdleTimerDisabled = true  // a slow answer shouldn't lock the screen

        task = Task {
            var stats: GenerationStats?
            var failure: Error?
            var lastSave = Date()
            do {
                let stream: AsyncThrowingStream<Generation, Error>
                if mode == .mac {
                    live.phase = .waiting
                    var macModel = macModel
                    if mac.route.host == nil { await mac.resolve() }
                    // No model yet (a fresh install), or one the Mac no longer serves (a chat from
                    // when it ran Ollama): the Mac serves one model, Splash's, and that answers.
                    if macModel.isEmpty || (!mac.models.isEmpty && !mac.models.contains(macModel)) {
                        macModel = mac.modelName
                        live.macModel = macModel
                        if conversation.modelContext != nil, !conversation.isDeleted { conversation.macModel = macModel }
                    }
                    let search = conversation.webSearch && WebSearcher.hasKey
                    (stream, _) = try await mac.stream(history, thinking: thinking, model: macModel, search: search)
                    conversation.tokenLimit = mac.contextLength
                } else {
                    let model = store.model
                    guard store.isReady else { throw EngineError.notDownloaded }
                    let llama = try await load()
                    try Task.checkCancellation()
                    // A chat with images: load the projector beside the model, if it's here.
                    if history.contains(where: \.hasImages), !llama.hasVision, store.hasProjector {
                        try await llama.loadVision(projector: store.url(for: model.projector).path)
                        try Task.checkCancellation()
                    }
                    let checkpoint = self.checkpoint(for: conversation, model: model, llama: llama)
                    live.phase = .waiting
                    conversation.tokenLimit = llama.contextLength
                    // Too long for the model: drop the oldest turns if that's wanted, else say so.
                    if await llama.countTokens(history, thinking: thinking) > llama.promptLimit {
                        guard trim || UserDefaults.standard.bool(forKey: Self.autoTrimKey),
                              let start = await fittingStart(for: conversation, system: system, llama: llama)
                        else { throw LlamaError.contextFull }
                        conversation.historyStart = start
                        history = [system] + conversation.history(before: conversation.messages.count - 1)
                        live.trimmed = true
                    }
                    try Task.checkCancellation()
                    // A search on device keeps three short results: the context is 8K, not the computer's 16K.
                    let search: (@Sendable (WebSearch) async -> WebSearch)? = system.declaresWebSearch
                        ? { @Sendable asked in await WebSearcher.search(asked.query, topic: asked.topic, results: 3, excerpt: 700) } : nil
                    stream = llama.generate(
                        history, sampling: model.sampling, thinking: thinking, checkpoint: checkpoint,
                        search: search)
                }
                for try await event in stream {
                    switch event {
                    case .reading(let p): live.phase = .reading(p)
                    case .thinking(let t): live.append(thinking: t)
                    case .text(let t): live.append(text: t)
                    case .searching(let q): live.phase = .searching(q)
                    case .searched(let s):
                        live.add(search: s)
                        write(live, to: conversation, finished: false)  // the sources show as soon as they're in
                    case .done(let s): stats = s
                    }
                    if Date().timeIntervalSince(lastSave) > 5 {  // so a crash keeps most of the answer
                        write(live, to: conversation, finished: false)
                        lastSave = .now
                    }
                }
            } catch is CancellationError {
            } catch LlamaError.cancelled {
            } catch {
                failure = error
            }
            finish(live, in: conversation, stats: stats, error: failure)
        }
    }

    private func finish(_ live: LiveReply, in conversation: Conversation, stats: GenerationStats?, error: Error?) {
        // Under the answer: the model that wrote it, then only what the answer can't do without.
        let title = live.mode == .mac ? MacLink.displayName(live.macModel) : live.modelTitle
        var parts = [title]
        if stats == nil && error == nil { parts.insert(live.stopNote ?? "Stopped", at: 0) }
        if live.trimmed { parts.append("Earlier messages left out to fit") }
        // A reply that ran into a limit says so instead of just ending.
        let cutOff: StopReason? = switch stats?.stopReason {
        case .maxTokens?: .maxTokens
        case .contextFull?: .contextFull
        default: nil
        }
        switch cutOff {
        case .maxTokens?: parts.append("Cut off at the length limit. Ask it to continue.")
        case .contextFull?: parts.append("Cut off: this chat is full")
        default: break
        }
        // B of a comparison: stamped with A's compareID. The chat stays on B's model, which wrote
        // the answer it shows, unless B has nothing to show.
        let pair = comparison.flatMap { $0.reply == live.id ? $0 : nil }
        var metrics = ReplyMetrics(
            modeRaw: live.mode.rawValue, macModel: live.mode == .mac ? live.macModel : nil, modelTitle: title)
        metrics.thinking = live.thinkingAsked
        metrics.trimmed = live.trimmed ? true : nil
        metrics.cutOff = cutOff?.rawValue
        metrics.stopped = stats == nil && error == nil ? true : nil
        if pair != nil, let id = comparing?.id { metrics.compareID = id }
        write(live, to: conversation, finished: true) {
            $0.footnote = parts.joined(separator: " · ")
            $0.error = error?.localizedDescription
            $0.errorKind = error.map(Self.kind)
            $0.cutOff = cutOff
            $0.metrics = metrics
        }
        if let pair {
            // B produced nothing (failed, or stopped before any answer): A is shown again, so the
            // question keeps its answer in the history, and the pair is undone, since there's
            // nothing to compare. A B stopped with some text stays a pair.
            if live.text.isEmpty || error != nil, conversation.modelContext != nil, !conversation.isDeleted,
               let i = conversation.index(of: live.id) {
                if let c = conversation.messages[i].comparison {
                    for v in [c.a, c.b] {
                        conversation.messages[i].updateMetrics(ofVersion: v) { $0?.compareID = nil; $0?.preferred = nil }
                    }
                    conversation.messages[i].showVersion(c.a)
                }
                conversation.mode = pair.mode
                conversation.macModel = pair.macModel
                conversation.thinking = pair.thinking
                try? conversation.modelContext?.save()
            }
            comparison = nil
            comparing = nil
        }
        if let stats, conversation.modelContext != nil, !conversation.isDeleted {
            conversation.tokensUsed = stats.promptTokens + stats.generatedTokens
            try? conversation.modelContext?.save()
        }
        // A few words from Apple Intelligence in place of the question, once there's an answer.
        if stats != nil, error == nil, conversation.modelContext != nil, !conversation.isDeleted {
            ChatTitler.shared.titleIfNeeded(conversation)
        }
        if stats != nil, Date().timeIntervalSince(live.started) > 5 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)  // you may have put it down
        }
        self.live = nil
        running = nil
        task = nil
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
        pruneStates()
    }

    /// Copies the live reply into the stored message, unless the chat was deleted meanwhile.
    private func write(
        _ live: LiveReply, to conversation: Conversation, finished: Bool, extra: (inout StoredMessage) -> Void = { _ in }
    ) {
        guard conversation.modelContext != nil, !conversation.isDeleted,
              let i = conversation.index(of: live.id) else { return }
        conversation.messages[i].content = live.text
        conversation.messages[i].thinking = live.thinking
        conversation.messages[i].searches = live.searches.isEmpty ? nil : live.searches
        conversation.messages[i].finished = finished
        extra(&conversation.messages[i])
        conversation.lastActive = .now
        try? conversation.modelContext?.save()
    }

    /// The user's own instructions for new chats (Settings > Personalization), in place of the
    /// default ones; empty for the default.
    nonisolated static let customPromptKey = "customPrompt"

    /// The default instructions, as the Personalization page shows them to start from.
    nonisolated static let defaultInstructions = """
        You are Lantern, a helpful assistant running privately on the user's own device. Answer \
        clearly and concisely, and use lists or numbered steps when they make an answer easier to follow.
        """

    /// The user's instructions, or nil for the default (none set, or the default as it was).
    nonisolated static var customInstructions: String? {
        let text = (UserDefaults.standard.string(forKey: customPromptKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == defaultInstructions ? nil : text
    }

    /// The prompt new chats are created with. The date is the day the chat starts: it's stored on
    /// the chat and never changes, so the models' caches and saved states stay valid overnight.
    /// Custom instructions replace the default text; the date always follows them, since a model
    /// that searches or is asked about "today" needs it.
    nonisolated static func systemPrompt(now: Date = .now) -> String {
        let date = now.formatted(date: .complete, time: .omitted)
        if let custom = customInstructions {
            return custom + "\n\nThis conversation began on \(date)."
        }
        return """
            You are Lantern, a helpful assistant running privately on the user's own device. This \
            conversation began on \(date). Answer clearly and \
            concisely, and use lists or numbered steps when they make an answer easier to follow.
            """
    }

    /// The chat's own prompt; chats from before prompts were stored get one dated when they began.
    /// The chat's system message for `mode`: its frozen prompt, declaring web search to a model on
    /// this device when the chat searches (and there's a key) (the templates put tools in the system turn; a model on a
    /// computer is offered it with each request instead). Built the same way for `prepare`, so the
    /// cache it readies is the one the reply starts from.
    private func systemMessage(of conversation: Conversation, mode: Mode) -> ChatMessage {
        let tools = mode.isOnDevice && conversation.webSearch && WebSearcher.hasKey ? [WebSearch.toolName] : []
        return ChatMessage(role: .system, content: frozenSystemPrompt(of: conversation), tools: tools)
    }

    private func frozenSystemPrompt(of conversation: Conversation) -> String {
        if conversation.systemPrompt.isEmpty { conversation.systemPrompt = Self.systemPrompt(now: conversation.created) }
        return conversation.systemPrompt
    }

    private static func kind(of error: Error) -> ReplyErrorKind {
        switch error {
        case EngineError.notDownloaded: .notDownloaded
        case LlamaError.contextFull: .contextFull
        case LlamaError.loadFailed, LlamaError.contextFailed: .loadFailed
        case let error as MacError: error.kind
        case is URLError: .macUnreachable
        default: .other
        }
    }

    // MARK: - A chat that no longer fits

    /// UserDefaults key (Bool, off by default). When on, a chat too long for the model drops its
    /// oldest turns by itself instead of failing with `.contextFull`.
    static let autoTrimKey = "context.autoTrim"
    /// After a reply failed with `.contextFull`: leaves the oldest turns out (they stay visible,
    /// the model just no longer sees them; the system prompt is kept) and answers again.
    func continueTrimmed(in conversation: Conversation) {
        guard !isBusy, let last = conversation.messages.last else { return }
        if !last.isUser {
            guard last.error != nil || last.content.isEmpty else { return }  // a real answer: nothing to redo
            conversation.messages.removeLast()
        }
        guard conversation.messages.last?.isUser == true else { return }
        generate(in: conversation, trim: true)
    }

    /// The other way out of a full chat: a new one that starts with the last
    /// exchange, so the thread isn't lost. Inserted next to `conversation`; the caller selects it.
    func continueInNewChat(from conversation: Conversation) -> Conversation {
        let next = Conversation(mode: conversation.mode)
        next.thinking = conversation.thinking
        next.webSearch = conversation.webSearch
        next.title = conversation.title
        // The last question and its answer, if they're short enough to be worth carrying over.
        let usable = conversation.messages.filter { $0.error == nil && !$0.content.isEmpty && $0.finished }
        var tail = Array(usable.suffix(2))
        if tail.first?.isUser == false { tail.removeFirst() }
        if tail.count == 2, tail.reduce(0, { $0 + $1.content.utf8.count }) < 8000 {
            next.messages = tail.map { StoredMessage(isUser: $0.isUser, content: $0.content, footnote: $0.footnote) }
        }
        conversation.modelContext?.insert(next)
        try? conversation.modelContext?.save()
        return next
    }

    /// The first message to keep so the chat fits with room to grow: the oldest turns go first, a
    /// turn at a time, down to at most the latest question. Nil if even that is too long.
    private func fittingStart(for conversation: Conversation, system: ChatMessage, llama: LlamaModel) async -> Int? {
        let end = conversation.messages.count - 1  // the reply being written
        let starts = conversation.messages[..<end].indices.filter { $0 > conversation.historyStart && conversation.messages[$0].isUser }
        let thinking = conversation.thinking
        let budget = llama.promptLimit * 2 / 3
        for (n, start) in starts.enumerated() {
            let kept = conversation.messages[start..<end].compactMap { $0.chatMessage }
            let tokens = await llama.countTokens([system] + kept, thinking: thinking)
            if tokens <= budget || (n == starts.count - 1 && tokens <= llama.promptLimit) { return start }
        }
        return nil
    }

    /// The most a chat can hold, in tokens.
    func contextLimit(for mode: Mode) -> Int {
        mode.isOnDevice ? Int(llama?.contextLength ?? Int(store.model.options.contextLength)) : mac.contextLength
    }

    /// Whether attached images are seen: on this device once the projector is here, on the Mac
    /// if its model has vision (checked when sending).
    func canSeeImages(_ mode: Mode) -> Bool { mode.isOnDevice ? store.hasProjector : true }

    // MARK: - Getting ready ahead of a message

    /// Loads the chat's model and gets its cache ready (its saved state, or for a new chat the
    /// system prompt), so the first reply doesn't wait for either. Call when a chat opens or
    /// typing starts; cheap to call again. Does nothing while a reply is being written.
    func prepare(_ conversation: Conversation) {
        guard !isBusy, !inBackground, conversation.modelContext != nil, !conversation.isDeleted else { return }
        prepared = conversation
        let mode = conversation.answeringMode
        if mode == .mac {
            mac.prepare()  // finds the Mac while the question is typed
            return
        }
        guard store.isReady else { return }
        let model = store.model
        let history = [systemMessage(of: conversation, mode: mode)]
            + conversation.history(before: conversation.messages.count)
        let thinking = conversation.thinking
        prepareCount += 1
        let turn = prepareCount
        Task {
            guard let llama = try? await load(), turn == prepareCount, !isBusy,
                  conversation.modelContext != nil, !conversation.isDeleted else { return }
            let checkpoint = self.checkpoint(for: conversation, model: model, llama: llama)
            await llama.prepare(history, thinking: thinking, checkpoint: checkpoint)
        }
    }

    // MARK: - Saved state

    private static let stateRoot = Folders.caches.appending(path: "kv")
    /// Above this, the least recently used chats' states are deleted. A long Gemma chat's state is
    /// a few tens of MB.
    private static let stateBudget: Int64 = 3_000_000_000

    /// Where a chat's model state is saved: Caches/kv/<id>. iOS may empty Caches when storage
    /// runs low, which only costs reading the chat again.
    static func stateDirectory(for conversation: Conversation) -> URL {
        if conversation.stateID.isEmpty { conversation.stateID = UUID().uuidString }
        return stateRoot.appending(path: conversation.stateID)
    }

    /// Where one model's state for a chat is saved: Caches/kv/<id>/<model id>. Each model keeps
    /// its own (a chat continued on another device, with another model, starts its own there).
    /// States saved before this sat in the chat's directory itself: `checkpoint` has the
    /// loaded model adopt its own from there (`LlamaModel.adoptLegacyState`, on its queue).
    static func stateDirectory(for conversation: Conversation, model: CatalogModel) -> URL {
        stateDirectory(for: conversation).appending(path: model.id)
    }

    /// The model's state directory for this chat, after queueing the move of any state it saved
    /// in the chat's directory before each model had its own. No file I/O here.
    private func checkpoint(for conversation: Conversation, model: CatalogModel, llama: LlamaModel) -> URL {
        let directory = Self.stateDirectory(for: conversation, model: model)
        llama.adoptLegacyState(from: directory.deletingLastPathComponent(), into: directory)
        return directory
    }

    /// Saves the loaded model's state for the chat it holds, if the last clean turn end isn't on
    /// disk yet. It normally is (it's written right after each reply), so this is a cheap way to be
    /// sure when leaving a chat. Unloading and leaving the app do it themselves.
    func saveState() {
        guard let llama else { return }
        Task { await llama.flush() }
    }

    /// Deletes a chat's saved model state. Call when the chat is deleted (before or after).
    func forgetState(for conversation: Conversation) {
        guard !conversation.stateID.isEmpty else { return }
        let directory = Self.stateRoot.appending(path: conversation.stateID)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
    }

    private func pruneStates() {
        let root = Self.stateRoot, budget = Self.stateBudget
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            let chats = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).map { directory in
                // Each model's state is in a folder of its own (and older ones beside them).
                let files = (fm.enumerator(at: directory, includingPropertiesForKeys: Array(keys))?.allObjects as? [URL]) ?? []
                let values = files.compactMap { try? $0.resourceValues(forKeys: keys) }
                return (directory, values.reduce(Int64(0)) { $0 + Int64($1.fileSize ?? 0) },
                        values.compactMap(\.contentModificationDate).max() ?? .distantPast)
            }
            var total = chats.reduce(Int64(0)) { $0 + $1.1 }
            for chat in chats.sorted(by: { $0.2 < $1.2 }) where total > budget {
                try? fm.removeItem(at: chat.0)
                total -= chat.1
            }
        }
    }

    // MARK: - Leaving the app

    /// iOS doesn't allow GPU work in the background, so an on-device reply stops when you leave,
    /// and a reply from the Mac gets the few seconds iOS allows to finish. The on-device model is
    /// then unloaded: its state is saved, and a suspended app holding gigabytes is the first to
    /// be killed.
    func didEnterBackground() {
        inBackground = true
        if let live {
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
        guard llama != nil || pendingLoad != nil else { return }
        let stopping = live?.mode.isOnDevice == true ? task : nil
        var release = UIBackgroundTaskIdentifier.invalid
        release = UIApplication.shared.beginBackgroundTask(withName: "Save chat state") {
            UIApplication.shared.endBackgroundTask(release)
            release = .invalid
        }
        Task {
            await stopping?.value
            if inBackground {  // not back in front already
                pendingLoad?.cancel.set()
                if let old = llama {
                    llama = nil
                    await old.flush()
                }
            }
            if release != .invalid { UIApplication.shared.endBackgroundTask(release) }
        }
    }


    /// Back in front: load the model for the chat that was open again.
    func didBecomeActive() {
        inBackground = false
        // Connections, and Lantern's own tailnet node's paths, may not have survived suspension:
        // check the route again while the user reads and types.
        if prepared?.answeringMode == .mac { mac.cameToFront() }
        if let prepared, llama == nil { prepare(prepared) }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }


    // MARK: - Models

    /// Quitting (the Mac): stops any reply, saves the model's state and frees it. llama.cpp's
    /// Metal device is torn down as the process exits and aborts if a model still holds its buffers.
    func shutDown() async {
        let running = task
        task?.cancel()
        await running?.value
        pendingLoad?.cancel.set()
        _ = try? await pendingLoad?.task.value
        pendingLoad = nil
        if let old = llama {
            llama = nil
            await old.flush()  // `old` is freed here, its last reference gone
        }
    }

    /// Frees the model's memory, after saving the state of the chat it holds. It's loaded again
    /// when next needed. Called on a memory warning.
    func unload() {
        guard !isBusy, let old = llama else { return }
        llama = nil
        Task { await old.flush() }  // `old` is freed when this is done
    }

    /// Removes this device's model: stops any reply on it, frees it, deletes its files.
    func deleteModel() async {
        if live?.mode.isOnDevice == true {
            let running = task
            stop()
            await running?.value
        }
        pendingLoad?.cancel.set()
        _ = try? await pendingLoad?.task.value
        if let old = llama {
            llama = nil
            await old.flush()
        }
        store.delete()
    }

    /// One load at a time, shared by whoever asks (a `prepare` and the message sent while it was
    /// still loading). Cancelling the caller's task (Stop) abandons the load.
    private func load() async throws -> LlamaModel {
        let model = store.model
        if let llama, loadedID == model.id { return llama }
        if let old = llama {  // the store moved on to a better model: free the old one first
            llama = nil
            await old.flush()
            if llama != nil || pendingLoad != nil { return try await load() }
        }
        let pending: PendingLoad
        if let current = pendingLoad {
            pending = current
        } else {
            var options = model.options
            // Gemma drafts with its MTP model once that's downloaded; until then it runs without.
            if store.has(model.drafter) { options.draftModel = store.url(for: model.drafter).path }
            let path = store.url(for: model.weights).path
            let cancel = CancelFlag()
            let report: @Sendable (Float) -> Void = { progress in
                Task { @MainActor in
                    if let live = self.live, case .loading = live.phase { live.phase = .loading(Double(progress)) }
                }
            }
            pending = PendingLoad(cancel: cancel, task: Task.detached(priority: .userInitiated) {
                try LlamaModel(path: path, options: options, progress: report, isCancelled: { cancel.isSet })
            })
            pendingLoad = pending
        }
        if let live, live.mode.isOnDevice { live.phase = .loading(0) }
        do {
            let loaded = try await withTaskCancellationHandler {
                try await pending.task.value
            } onCancel: {
                pending.cancel.set()
            }
            if pendingLoad === pending {
                pendingLoad = nil
                llama = loaded
                loadedID = model.id
            }
            guard let llama else { throw CancellationError() }
            return llama
        } catch {
            if pendingLoad === pending { pendingLoad = nil }
            throw error
        }
    }
}

/// A model on its way into memory.
private final class PendingLoad {
    let cancel: CancelFlag
    let task: Task<LlamaModel, Error>

    init(cancel: CancelFlag, task: Task<LlamaModel, Error>) {
        self.cancel = cancel
        self.task = task
    }
}

nonisolated final class CancelFlag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

/// The reply being written. Plain (not observed): the chat screen polls `revision` a few times a
/// second, so tokens arriving at 150 a second don't each cause a UI update.
final class LiveReply {
    enum Phase: Equatable {
        case loading(Double), waiting, reading(Double), thinking, answering
        /// Waiting for a web search the model asked for.
        case searching(String)

        /// The same for every progress value of a phase.
        fileprivate var step: Int {
            switch self {
            case .loading: 0
            case .waiting: 1
            case .reading: 2
            case .thinking: 3
            case .answering: 4
            case .searching: 5
            }
        }
    }

    let id: UUID
    let mode: Mode
    /// For `.mac`: the model answering, by id.
    var macModel = ""
    let started = Date()
    var phase: Phase = .waiting {
        didSet {
            revision += 1
            if phase.step != oldValue.step { phaseStarted = Date() }
        }
    }
    private(set) var thinking = ""
    private(set) var text = ""
    /// Web searches run so far, in order.
    private(set) var searches: [WebSearch] = []
    private(set) var revision = 0
    /// Why it stopped, if it was stopped for the user rather than by them.
    var stopNote: String?
    /// When the current phase began (loading, reading, thinking…), for "Thinking · 12 s".
    private(set) var phaseStarted = Date()
    /// On device: the model answering, as it was when the reply began.
    var modelTitle = ""
    /// Asked to think, or a Mac model that always does.
    var thinkingAsked = false
    /// The oldest turns were left out of what the model saw, to fit its context.
    var trimmed = false

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

    func add(search: WebSearch) {
        searches.append(search)
        revision += 1
    }
}

nonisolated enum EngineError: LocalizedError {
    case notDownloaded
    var errorDescription: String? { "\(CatalogModel.device.name) hasn't been downloaded yet." }
}
