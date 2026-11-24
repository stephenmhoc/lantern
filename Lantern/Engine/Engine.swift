import BackgroundTasks
import Foundation
import LlamaKit
import Observation
import os
import SwiftData
import UIKit
import UserNotifications

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
    /// The model being loaded, for a chat that's waiting or ahead of one (`prepare`).
    private(set) var loadingModel: CatalogModel?
    /// Set while a model self-test runs, which also blocks chats.
    private(set) var testing: CatalogModel?
    var isBusy: Bool { running != nil || testing != nil }
    /// The last finished reply's numbers (prompt, reused, generated tokens), for checks.
    @ObservationIgnored private(set) var lastStats: GenerationStats?

    @ObservationIgnored private var llama: LlamaModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingLoad: PendingLoad?
    @ObservationIgnored private var prepared: (mode: Mode, conversation: Conversation)?
    @ObservationIgnored private var prepareCount = 0
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// iOS 26+: the `BGContinuedProcessingTask` keeping the running reply going after leaving the
    /// app, once the system has started it (`AnyObject` so the property exists on iOS 18).
    @ObservationIgnored private var continued: AnyObject?
    /// The identifier of the request submitted for the running reply, until it ends.
    @ObservationIgnored private var continuedID: String?

    init() {
        store.canReplaceFile = { [weak self] model in
            guard let self else { return true }
            if isBusy || loadingModel == model { return false }
            if loadedModel == model { unload() }
            return true
        }
        // The model's cache and buffers are the app's largest dirty memory, and what's in them is
        // saved: under memory pressure, give them back rather than be killed.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unload() }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-featuretest") { Task { await runFeatureTest() } }
        #endif
    }

    func model(for mode: Mode) -> CatalogModel? {
        CatalogModel.preferred(for: mode, downloaded: store.downloaded)
    }

    // MARK: - Chats

    func send(_ text: String, attachments: [Attachment] = [], in conversation: Conversation) {
        guard !isBusy, !text.isEmpty || !attachments.isEmpty else { return }
        if conversation.messages.isEmpty { conversation.title = String((text.isEmpty ? attachments[0].name : text).prefix(60)) }
        _ = frozenSystemPrompt(of: conversation)  // so the date note compares with the chat's own date
        var message = StoredMessage(isUser: true, content: text)
        message.attachments = attachments.isEmpty ? nil : attachments
        message.dateNote = conversation.dateNote()
        conversation.messages.append(message)
        generate(in: conversation)
    }

    /// Replaces the last reply with a new one, optionally from another mode. The answer it replaces
    /// (and its own earlier versions) are kept as the new one's other versions.
    /// `macModel`: for `.mac`, which of the Mac's models (nil keeps the chat's).
    func retry(in conversation: Conversation, mode: Mode, macModel: String? = nil) {
        guard !isBusy, let old = conversation.messages.last, !old.isUser else { return }
        let kept = old.allVersions.list.filter { !$0.content.isEmpty }
        conversation.messages.removeLast()
        conversation.mode = mode
        if let macModel { conversation.macModel = macModel }
        generate(in: conversation, versions: kept)
    }

    /// Stops the running reply and starts it again in `mode` (e.g. E4B is too slow: use E2B).
    /// What it had written so far is kept as a version, as Retry does.
    func restart(in conversation: Conversation, mode: Mode) {
        let previous = task
        live?.stopNote = "Stopped for \(mode.title)"
        previous?.cancel()
        Task {
            await previous?.value
            retry(in: conversation, mode: mode)
        }
    }

    /// Stops the reply, including while its model is still loading.
    func stop() { task?.cancel() }

    private func generate(in conversation: Conversation, trim: Bool = false, versions: [ReplyVersion] = []) {
        var reply = StoredMessage(isUser: false, finished: false)
        reply.versions = versions.isEmpty ? nil : versions
        conversation.messages.append(reply)
        conversation.lastActive = .now
        try? conversation.modelContext?.save()

        let mode = conversation.mode
        let thinking = conversation.thinking
        let system = ChatMessage(role: .system, content: frozenSystemPrompt(of: conversation))
        var history = [system] + conversation.history(before: conversation.messages.count - 1)
        let checkpoint = Self.stateDirectory(for: conversation)
        let macModel = conversation.resolvedMacModel
        if mode == .mac, conversation.macModel.isEmpty, !macModel.isEmpty { conversation.macModel = macModel }
        let live = LiveReply(id: reply.id, mode: mode)
        live.macModel = macModel
        self.live = live
        running = conversation.persistentModelID
        UIApplication.shared.isIdleTimerDisabled = true  // a slow answer shouldn't lock the screen
        beginContinuedProcessing(mode: mode, chatTitle: conversation.title)

        task = Task {
            var stats: GenerationStats?
            var failure: Error?
            var lastSave = Date()
            var lastProgress = Date()
            var pieces = 0
            var statsKey: String?
            do {
                let stream: AsyncThrowingStream<Generation, Error>
                if mode == .mac {
                    live.phase = .waiting
                    var macModel = macModel
                    if macModel.isEmpty {
                        // No model picked yet (a fresh install): ask the Mac, which picks a default.
                        if mac.route.host == nil { await mac.resolve() }
                        macModel = mac.modelName
                        live.macModel = macModel
                        if conversation.modelContext != nil, !conversation.isDeleted { conversation.macModel = macModel }
                    }
                    stream = try await mac.stream(history, thinking: thinking, model: macModel)
                    statsKey = "mac:\(macModel)"
                    conversation.tokenLimit = mac.contextLength
                } else {
                    guard let model = model(for: mode) else { throw EngineError.notDownloaded(mode) }
                    guard store.states[model.id] == .ready else { throw EngineError.notDownloaded(mode) }
                    let llama = try await load(model)
                    try Task.checkCancellation()
                    // A chat with images: load the projector beside the model, if it's here.
                    if history.contains(where: \.hasImages), !llama.hasVision,
                       let projector = model.projector, store.states[projector.id] == .ready {
                        try await llama.loadVision(projector: store.url(for: projector).path)
                        try Task.checkCancellation()
                    }
                    live.phase = .waiting
                    statsKey = model.id
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
                    stream = llama.generate(history, sampling: model.sampling, thinking: thinking, checkpoint: checkpoint)
                }
                for try await event in stream {
                    switch event {
                    case .reading(let p): live.phase = .reading(p)
                    case .thinking(let t): live.append(thinking: t)
                    case .text(let t): live.append(text: t)
                    case .done(let s): stats = s
                    }
                    pieces += 1
                    if Date().timeIntervalSince(lastProgress) > 0.5 {
                        reportContinuedProgress(pieces)
                        lastProgress = .now
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
            finish(live, in: conversation, stats: stats, error: failure, statsKey: statsKey)
        }
    }

    private func finish(
        _ live: LiveReply, in conversation: Conversation, stats: GenerationStats?, error: Error?, statsKey: String?
    ) {
        var parts = [live.mode == .mac ? "\(MacLink.displayName(live.macModel)) on your Mac" : loadedModel?.name ?? live.mode.title]
        if let stats, stats.generatedTokens > 0 { parts.append(String(format: "%.1f tok/s", stats.tokensPerSecond)) }
        if let first = live.firstTokenSeconds { parts.append(String(format: "%.1f s to first token", first)) }
        if live.mode == .mac, stats != nil {
            // Where the wait before the first token went: finding the Mac, connecting, the Mac
            // loading the model, reading the chat. Only the parts that took noticeable time.
            let t = mac.lastTimings
            if case .tailnet(_, let viaApp) = mac.route { parts.append(viaApp ? "via the Tailscale app" : "via tailnet") }
            let steps: [(String, Double?)] = [
                ("found the Mac", t.findSeconds), ("connected", t.connectSeconds),
                ("loaded the model", t.loadSeconds), ("read the chat", t.readSeconds),
            ]
            for (what, seconds) in steps {
                if let seconds, seconds >= 0.3 { parts.append(String(format: "\(what) in %.1f s", seconds)) }
            }
        }
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
        write(live, to: conversation, finished: true) {
            $0.footnote = parts.joined(separator: " · ")
            $0.error = error?.localizedDescription
            $0.errorKind = error.map(Self.kind)
            $0.cutOff = cutOff
        }
        lastStats = stats
        if let stats, conversation.modelContext != nil, !conversation.isDeleted {
            conversation.tokensUsed = stats.promptTokens + stats.generatedTokens
            try? conversation.modelContext?.save()
        }
        if let stats, stats.generatedTokens > 0, let statsKey, let first = live.firstTokenSeconds {
            // A reply that had to load the model first says nothing about the usual wait.
            let loaded = live.waitedForLoad || (live.mode == .mac && mac.lastTimings.loadSeconds >= 1)
            TypicalSpeed.record(firstToken: loaded ? nil : first, tokensPerSecond: stats.tokensPerSecond, for: statsKey)
        }
        if stats != nil, Date().timeIntervalSince(live.started) > 5 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)  // you may have put it down
        }
        if inBackground, stats != nil || error != nil {
            notifyFinished(conversation, reply: live, failed: error != nil)
        }
        self.live = nil
        running = nil
        task = nil
        UIApplication.shared.isIdleTimerDisabled = false
        endContinuedProcessing(success: error == nil)
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
        conversation.messages[i].finished = finished
        extra(&conversation.messages[i])
        conversation.lastActive = .now
        try? conversation.modelContext?.save()
    }

    /// The prompt new chats are created with. The date is the day the chat starts: it's stored on
    /// the chat and never changes, so the models' caches and saved states stay valid overnight.
    nonisolated static func systemPrompt(now: Date = .now) -> String {
        """
        You are Lantern, a helpful assistant running privately on the user's own device. This \
        conversation began on \(now.formatted(date: .complete, time: .omitted)). Answer clearly and \
        concisely, and use lists or numbered steps when they make an answer easier to follow.
        """
    }

    /// The chat's own prompt; chats from before prompts were stored get one dated when they began.
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

    /// The other way out of a full chat: a new one in the same mode that starts with the last
    /// exchange, so the thread isn't lost. Inserted next to `conversation`; the caller selects it.
    func continueInNewChat(from conversation: Conversation) -> Conversation {
        let next = Conversation(mode: conversation.mode)
        next.thinking = conversation.thinking
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

    /// How full a chat's context is: live while it's answering on this device, else as its last
    /// reply left it. Nil before the first reply.
    func contextUsage(for conversation: Conversation) -> (used: Int, limit: Int)? {
        if running == conversation.persistentModelID, live?.mode.isOnDevice == true, let llama {
            return (llama.tokensInContext, llama.contextLength)
        }
        return conversation.tokenLimit > 0 ? (conversation.tokensUsed, conversation.tokenLimit) : nil
    }

    /// The most a chat in this mode can hold, in tokens, before any reply has said so.
    func contextLimit(for mode: Mode) -> Int {
        if mode == .mac { return mac.contextLength }
        if let llama, loadedModel?.tier == mode { return llama.contextLength }
        return Int(model(for: mode)?.options.contextLength ?? ModelOptions().contextLength)
    }

    /// Whether images attached in this mode are seen: on this device once the model's projector
    /// is downloaded, on the Mac if its model has vision (checked when sending).
    func canSeeImages(_ mode: Mode) -> Bool {
        guard mode.isOnDevice else { return true }
        return model(for: mode)?.projector.map { store.states[$0.id] == .ready } ?? false
    }

    /// What this mode's model usually does on this device, from past replies. Nil until it has answered.
    func typicalSpeed(for mode: Mode, macModel: String? = nil) -> TypicalSpeed? {
        if mode == .mac { return TypicalSpeed.stored(for: "mac:\(macModel ?? mac.modelName)") }
        return model(for: mode).flatMap { TypicalSpeed.stored(for: $0.id) }
    }

    // MARK: - Getting ready ahead of a message

    /// Loads the mode's model and gets its cache ready for this chat (its saved state, or for a
    /// new chat the system prompt), so the first reply doesn't wait for either. Call when a chat
    /// opens or typing starts; cheap to call again. Does nothing while a reply is being written.
    func prepare(mode: Mode, for conversation: Conversation) {
        guard !isBusy, !inBackground, conversation.modelContext != nil, !conversation.isDeleted else { return }
        prepared = (mode, conversation)
        if mode == .mac {
            mac.warm(conversation.resolvedMacModel)  // Ollama loads the model while the question is typed
            return
        }
        guard let model = model(for: mode), store.states[model.id] == .ready else { return }
        let history = [ChatMessage(role: .system, content: frozenSystemPrompt(of: conversation))]
            + conversation.history(before: conversation.messages.count)
        let thinking = conversation.thinking
        let checkpoint = Self.stateDirectory(for: conversation)
        prepareCount += 1
        let turn = prepareCount
        Task {
            guard let llama = try? await load(model), turn == prepareCount, !isBusy else { return }
            await llama.prepare(history, thinking: thinking, checkpoint: checkpoint)
        }
    }

    // MARK: - Saved state

    private static let stateRoot = URL.cachesDirectory.appending(path: "kv")
    /// Above this, the least recently used chats' states are deleted. A long Gemma chat's state is
    /// a few tens of MB.
    private static let stateBudget: Int64 = 3_000_000_000

    /// Where a chat's model state is saved: Caches/kv/<id>. iOS may empty Caches when storage
    /// runs low, which only costs reading the chat again.
    static func stateDirectory(for conversation: Conversation) -> URL {
        if conversation.stateID.isEmpty { conversation.stateID = UUID().uuidString }
        return stateRoot.appending(path: conversation.stateID)
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
                let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
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

    /// On iOS 26+, a reply whose continued-processing task the system started keeps going (an
    /// on-device one only where background GPU is allowed; see `beginContinuedProcessing`).
    /// Otherwise iOS doesn't allow GPU work in the background, so an on-device reply stops when you
    /// leave, and a reply from the Mac gets the few seconds iOS allows to finish. The on-device
    /// model is then unloaded (after a continued reply ends): its state is saved, and a suspended
    /// app holding gigabytes is the first to be killed.
    func didEnterBackground() {
        inBackground = true
        if let live {
            if continued != nil {
                askToNotifyQuietly()
            } else if live.mode.isOnDevice {
                live.stopNote = "Stopped when you left Lantern"
                stop()
            } else {
                askToNotifyQuietly()
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
            // Back in front already, or a self-test is running: keep the model.
            if inBackground, testing == nil, live?.mode.isOnDevice != true {
                pendingLoad?.cancel.set()
                if let old = llama {
                    llama = nil
                    loadedModel = nil
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
        // check the route again and keep the model warm while the user reads and types.
        if prepared?.mode == .mac { mac.cameToFront() }
        if let prepared, llama == nil { prepare(mode: prepared.mode, for: prepared.conversation) }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Continued processing (iOS 26+)

    /// Request identifiers: the prefix is in Info.plist's BGTaskSchedulerPermittedIdentifiers as
    /// `<prefix>.*`; each reply submits its own, registered just before.
    static let continuedPrefix = "com.merimerimeri.Lantern.reply"
    /// Rough reply length for the system's progress display; raised as a reply runs past it.
    private static let expectedPieces: Int64 = 600

    /// Asks iOS to let the reply that's starting keep going if the user leaves. On-device replies
    /// need the GPU in the background, which needs an entitlement and a device that supports it:
    /// without both, nothing is submitted and leaving stops the reply as before. Ollama replies
    /// only need the network. With `.fail`, a request iOS can't start now is refused outright.
    private func beginContinuedProcessing(mode: Mode, chatTitle: String) {
        guard #available(iOS 26, *) else { return }
        let needsGPU = mode.isOnDevice && !Self.onCPU
        if needsGPU, !BGTaskScheduler.supportedResources.contains(.gpu) { return }
        let id = "\(Self.continuedPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask, let self, self.continuedID == id, self.live != nil else {
                    task.setTaskCompleted(success: true)  // the reply ended before iOS started this
                    return
                }
                task.progress.totalUnitCount = Self.expectedPieces
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.continuedID == id else { return }
                        self.live?.stopNote = "Stopped when iOS needed Lantern to pause"
                        self.stop()  // `finish` saves the reply and completes the task
                    }
                }
                self.continued = task
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: id, title: mode == .mac ? "Your Mac is answering" : "Lantern is answering", subtitle: chatTitle)
        request.strategy = .fail
        if needsGPU { request.requiredResources = .gpu }
        do {
            try BGTaskScheduler.shared.submit(request)
            continuedID = id
        } catch {
            Logger(subsystem: "Lantern", category: "Engine").info("Continued processing not available: \(error.localizedDescription)")
        }
    }

    /// llama.cpp runs on the CPU in the simulator, so an on-device reply needs no background GPU there.
    private static var onCPU: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private func reportContinuedProgress(_ pieces: Int) {
        guard #available(iOS 26, *), let task = continued as? BGContinuedProcessingTask else { return }
        let done = Int64(pieces)
        if done >= task.progress.totalUnitCount * 9 / 10 { task.progress.totalUnitCount = done * 5 / 4 + 1 }
        task.progress.completedUnitCount = done
    }

    private func endContinuedProcessing(success: Bool) {
        continuedID = nil
        guard #available(iOS 26, *), let task = continued as? BGContinuedProcessingTask else { return }
        continued = nil
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.setTaskCompleted(success: success)
    }

    // MARK: - Telling the user a reply finished while away

    /// Quiet (provisional) notifications need no prompt, so this never interrupts; a user who
    /// allowed Lantern's reminders already gets full ones.
    private func askToNotifyQuietly() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) }
    }

    private func notifyFinished(_ conversation: Conversation, reply live: LiveReply, failed: Bool) {
        let content = UNMutableNotificationContent()
        content.title = conversation.title
        content.body = failed ? "The reply didn't finish. Open Lantern to try again."
            : live.text.isEmpty ? "Answer ready." : Markdown.firstSentence(live.text)
        content.threadIdentifier = conversation.stateID
        content.sound = .default
        let request = UNNotificationRequest(identifier: "reply-\(live.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Models

    /// Frees the model's memory, after saving the state of the chat it holds. It's loaded again
    /// when next needed. Called on a memory warning, on leaving the app, and from Settings.
    func unload() {
        guard !isBusy, let old = llama else { return }
        llama = nil
        loadedModel = nil
        Task { await old.flush() }  // `old` is freed when this is done
    }

    /// One load at a time, shared by whoever asks for the same model (a `prepare` and the message
    /// sent while it was still loading). Cancelling the caller's task (Stop) abandons the load.
    private func load(_ model: CatalogModel) async throws -> LlamaModel {
        while true {
            if let llama, loadedModel == model { return llama }
            guard let other = pendingLoad, other.model != model else { break }
            other.cancel.set()  // a different model was on its way: it has to go first
            _ = try? await other.task.value
            if pendingLoad === other { pendingLoad = nil }
        }
        let pending: PendingLoad
        if let current = pendingLoad {
            pending = current
        } else {
            if let old = llama {  // free the old model before mapping the new one
                llama = nil
                loadedModel = nil
                await old.flush()
                // Anything may have happened meanwhile: start over if someone else got here first.
                if llama != nil || pendingLoad != nil { return try await load(model) }
            }
            let path = store.url(for: model).path
            let options = model.options
            let cancel = CancelFlag()
            let report: @Sendable (Float) -> Void = { progress in
                Task { @MainActor in
                    if let live = self.live, case .loading = live.phase { live.phase = .loading(Double(progress)) }
                }
            }
            pending = PendingLoad(model: model, cancel: cancel, task: Task.detached(priority: .userInitiated) {
                try LlamaModel(path: path, options: options, progress: report, isCancelled: { cancel.isSet })
            })
            pendingLoad = pending
            loadingModel = model
        }
        if let live, live.mode == model.tier { live.phase = .loading(0) }
        do {
            let loaded = try await withTaskCancellationHandler {
                try await pending.task.value
            } onCancel: {
                pending.cancel.set()
            }
            if pendingLoad === pending {
                pendingLoad = nil
                loadingModel = nil
                llama = loaded
                loadedModel = model
            }
            guard let llama, loadedModel == model else { throw CancellationError() }
            return llama
        } catch {
            if pendingLoad === pending {
                pendingLoad = nil
                loadingModel = nil
            }
            throw error
        }
    }

    /// Loads a model and asks for a one-word answer: proof it works on this device, and its speed.
    func test(_ model: CatalogModel) async throws -> GenerationStats {
        guard !isBusy else { throw EngineError.busy }
        testing = model
        defer { testing = nil }
        let llama = try await load(model)
        var result = GenerationStats()
        let question = [ChatMessage(role: .user, content: "Reply with one word: ready.")]
        for try await event in llama.generate(question, sampling: model.sampling, maxTokens: 400) {
            if case .done(let s) = event { result = s }
        }
        return result
    }
}

/// A model on its way into memory.
private final class PendingLoad {
    let model: CatalogModel
    let cancel: CancelFlag
    let task: Task<LlamaModel, Error>

    init(model: CatalogModel, cancel: CancelFlag, task: Task<LlamaModel, Error>) {
        self.model = model
        self.cancel = cancel
        self.task = task
    }
}

nonisolated final class CancelFlag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

/// What a model usually does on this device: a running average over its replies, kept in
/// UserDefaults, for telling the user what to expect ("usually ~4 s").
nonisolated struct TypicalSpeed: Codable, Sendable {
    /// Seconds from sending to the first token, with the model already loaded.
    var firstToken: Double
    var tokensPerSecond: Double
    var replies: Int

    static func stored(for key: String) -> TypicalSpeed? {
        UserDefaults.standard.data(forKey: "speed.\(key)").flatMap { try? JSONDecoder().decode(TypicalSpeed.self, from: $0) }
    }

    /// Recent replies count for more, so the figure follows a model change or a hot device.
    static func record(firstToken: Double?, tokensPerSecond: Double, for key: String) {
        guard var speed = stored(for: key) ?? firstToken.map({ TypicalSpeed(firstToken: $0, tokensPerSecond: tokensPerSecond, replies: 0) })
        else { return }
        let weight = speed.replies == 0 ? 1 : 0.3
        if let firstToken { speed.firstToken += (firstToken - speed.firstToken) * weight }
        speed.tokensPerSecond += (tokensPerSecond - speed.tokensPerSecond) * weight
        speed.replies += 1
        if let data = try? JSONEncoder().encode(speed) { UserDefaults.standard.set(data, forKey: "speed.\(key)") }
    }
}

/// The reply being written. Plain (not observed): the chat screen polls `revision` a few times a
/// second, so tokens arriving at 150 a second don't each cause a UI update.
final class LiveReply {
    enum Phase: Equatable {
        case loading(Double), waiting, reading(Double), thinking, answering

        /// The same for every progress value of a phase.
        fileprivate var step: Int {
            switch self {
            case .loading: 0
            case .waiting: 1
            case .reading: 2
            case .thinking: 3
            case .answering: 4
            }
        }
    }

    let id: UUID
    let mode: Mode
    /// For `.mac`: the Ollama model answering.
    var macModel = ""
    let started = Date()
    var phase: Phase = .waiting {
        didSet {
            revision += 1
            if phase.step != oldValue.step { phaseStarted = Date() }
            if case .loading = phase { waitedForLoad = true }
        }
    }
    private(set) var thinking = ""
    private(set) var text = ""
    private(set) var revision = 0
    /// Why it stopped, if it was stopped for the user rather than by them.
    var stopNote: String?
    /// When the current phase began (loading, reading, thinking…), for "Thinking · 12 s".
    private(set) var phaseStarted = Date()
    /// Seconds from sending to the first token of thinking or answer. Nil until it arrives.
    private(set) var firstTokenSeconds: Double?
    /// The oldest turns were left out of what the model saw, to fit its context.
    var trimmed = false
    /// The model had to be loaded before this reply could start.
    private(set) var waitedForLoad = false

    init(id: UUID, mode: Mode) {
        self.id = id
        self.mode = mode
    }

    func append(thinking t: String) {
        if firstTokenSeconds == nil { firstTokenSeconds = Date().timeIntervalSince(started) }
        thinking += t
        phase = .thinking
    }

    func append(text t: String) {
        if firstTokenSeconds == nil { firstTokenSeconds = Date().timeIntervalSince(started) }
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
        case .notDownloaded(let mode): "\(mode.title) isn't on this device yet. Get it in Settings > Readiness."
        case .busy: "Lantern is answering. Try again when it's done."
        }
    }
}
