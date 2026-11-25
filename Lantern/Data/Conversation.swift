import Foundation
import LlamaKit
import SwiftData

@Model
final class Conversation {
    var title: String = "New chat"
    var created: Date = Date()
    /// Never used: Core Data, under SwiftData, reads the key `updated` as NSManagedObject's
    /// `isUpdated`, so every save stored it as 0 (1 January 2001). Kept so existing stores open.
    var updated: Date = Date()
    /// When the chat last changed (a turn started or ended): the sidebar's order and dates.
    /// Set to the reference date in chats from before it existed until `repairActivity` fills it.
    var lastActive: Date = Date(timeIntervalSinceReferenceDate: 0)
    var mode: Mode = Mode.fast
    /// In `.mac` mode, which of Ollama's models answers ("gemma4:31b-mlx"). Empty means the one
    /// last picked (`MacLink.modelKey`); the first reply fixes it, so the chat keeps its model.
    var macModel: String = ""
    var thinking: Thinking = Thinking.off
    /// Kept at the top of the sidebar.
    var pinned: Bool = false
    /// In order. Written when a turn starts and ends (and every few seconds while streaming), never
    /// per token: the live reply lives in `Engine.live` until then.
    var messages: [StoredMessage] = []
    /// What's typed in the message box but not sent, kept when switching chats.
    var draft: String = ""
    /// Fixed when the chat is created, date included. The models' caches and saved states start
    /// with it, so a prompt that changed at midnight would mean reading the whole chat again.
    /// Empty in chats from before this existed: `Engine` fills it in from `created` on first use.
    var systemPrompt: String = ""
    /// Names this chat's saved model state in Caches/kv. Empty until first needed.
    var stateID: String = ""
    /// Messages before this index are no longer sent to the model: dropped to fit its context.
    var historyStart: Int = 0
    /// The context the last reply left in use, and the model's limit, for showing how full the chat is.
    var tokensUsed: Int = 0
    var tokenLimit: Int = 0

    /// Fills `lastActive` in chats from before it existed: from `updated` where a save didn't
    /// zero it, else from when the chat began. Cheap; run once at launch.
    static func repairActivity(in context: ModelContext) {
        let unset = Date(timeIntervalSinceReferenceDate: 0)
        let chats = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.lastActive == unset }))) ?? []
        guard !chats.isEmpty else { return }
        for c in chats { c.lastActive = c.updated > unset ? c.updated : c.created }
        try? context.save()
    }

    init(mode: Mode) {
        self.mode = mode
        self.systemPrompt = Engine.systemPrompt()
        self.stateID = UUID().uuidString
    }

    /// What the model sees before message `index`: user turns and answers, including a stopped
    /// answer's partial text, but not failed or empty replies, nor turns dropped to fit the context.
    func history(before index: Int) -> [ChatMessage] {
        messages[min(historyStart, index)..<index].compactMap { $0.chatMessage }
    }

    /// The note to put before a new question when the day has changed since the model last heard
    /// the date (in the system prompt or an earlier note), else nil. "(Today is Monday, 23 November
    /// 2026.)" Stored on the message, so the turn is rendered the same every time it's sent.
    func dateNote(now: Date = .now) -> String? {
        let today = now.formatted(date: .complete, time: .omitted)
        let lastSaid = messages.last(where: { $0.dateNote != nil })?.dateNote ?? systemPrompt
        if lastSaid.isEmpty || lastSaid.contains(today) { return nil }
        return "(Today is \(today).)"
    }

    func index(of id: UUID) -> Int? { messages.firstIndex { $0.id == id } }

    /// The Ollama model this chat uses on the Mac.
    var resolvedMacModel: String {
        macModel.isEmpty ? UserDefaults.standard.string(forKey: MacLink.modelKey) ?? "" : macModel
    }

    /// What answers, for the picker, the sidebar and the inspector: "Gemma 4 E2B", "Gemma 4 31B".
    var modelTitle: String { mode == .mac ? MacLink.displayName(resolvedMacModel) : mode.title }
}

struct StoredMessage: Codable, Hashable, Identifiable {
    var id = UUID()
    var isUser: Bool
    var content = ""
    var thinking = ""
    /// Which model wrote it and how fast, e.g. "Gemma 4 E4B · 14.1 tok/s".
    var footnote: String?
    var error: String?
    /// False until a reply ends (finished, stopped or failed). A reply still false when nothing is
    /// generating was cut off by the app being killed.
    var finished = true
    /// What kind of failure `error` describes, for offering the right way out.
    var errorKind: ReplyErrorKind?
    /// Set when a reply was cut short by a limit rather than ended by the model or the user:
    /// `.maxTokens` (the reply-length limit) or `.contextFull` (the chat filled the context).
    var cutOff: StopReason?
    /// The other answers to the same question (from Retry), oldest first. Optional so messages saved
    /// before it existed still decode.
    var versions: [ReplyVersion]?
    /// Where this answer sits among `versions`, oldest first; nil means it's the newest.
    var versionIndex: Int?
    /// How long the model thought before answering, when the chat screen saw it happen.
    var thoughtSeconds: Double?
    /// Files sent with a question: their text (or the image) is part of what the model sees.
    var attachments: [Attachment]?
    /// "(Today is …)", put before a question sent on a later day than the chat began (see
    /// `Conversation.dateNote`). Fixed once sent.
    var dateNote: String?
    /// How the reply was made and how fast (`ReplyMetrics`). Nil for questions, for replies from
    /// before it existed and for ones that failed before any timing.
    var metrics: ReplyMetrics?

    nonisolated var hasAttachments: Bool { !(attachments ?? []).isEmpty }

    /// This turn as the model sees it, or nil if it isn't sent (failed or empty). A question's text
    /// is preceded by its date note and its files' text, in a fixed format, so the turn renders
    /// byte for byte the same each time (a saved cache is only reused for an identical prefix).
    nonisolated var chatMessage: ChatMessage? {
        guard error == nil, !content.isEmpty || hasAttachments else { return nil }
        guard isUser else { return ChatMessage(role: .assistant, content: content) }
        var parts: [String] = []
        if let dateNote { parts.append(dateNote) }
        for file in attachments ?? [] where file.image == nil {
            parts.append("<file name=\"\(file.name)\">\n\(file.text)\n</file>")
        }
        if !content.isEmpty { parts.append(content) }
        return ChatMessage(role: .user, content: parts.joined(separator: "\n\n"),
                           images: (attachments ?? []).compactMap(\.image))
    }

    /// Every answer to this question, oldest first, and which one this message shows.
    var allVersions: (list: [ReplyVersion], current: Int) {
        let others = versions ?? []
        let current = min(versionIndex ?? others.count, others.count)
        var list = others
        list.insert(ReplyVersion(self), at: current)
        return (list, current)
    }

    /// Shows answer `index` of `allVersions`; the history sent to the model follows it.
    mutating func showVersion(_ index: Int) {
        var (list, current) = allVersions
        guard index != current, list.indices.contains(index) else { return }
        let chosen = list.remove(at: index)
        content = chosen.content
        thinking = chosen.thinking
        footnote = chosen.footnote
        error = chosen.error
        thoughtSeconds = chosen.thoughtSeconds
        metrics = chosen.metrics
        versions = list
        versionIndex = index == list.count ? nil : index
    }
}

/// A file sent with a question. Only what the model needs is kept: the name, the text taken out
/// of it, and for an image the downscaled JPEG it's shown.
nonisolated struct Attachment: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var text = ""
    var image: Data?

    var isImage: Bool { image != nil }
    var symbol: String { isImage ? "photo" : name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text" }
}

/// One answer to a question, kept when Retry writes another.
struct ReplyVersion: Codable, Hashable {
    var content: String
    var thinking: String
    var footnote: String?
    var error: String?
    var thoughtSeconds: Double?
    var metrics: ReplyMetrics?

    init(_ m: StoredMessage) {
        content = m.content
        thinking = m.thinking
        footnote = m.footnote
        error = m.error
        thoughtSeconds = m.thoughtSeconds
        metrics = m.metrics
    }
}

extension StoredMessage {
    /// The two answers of a comparison on this reply, oldest (A) first, with their indices in
    /// `allVersions`: the newest pair sharing a `ReplyMetrics.compareID`. Nil when there's none.
    var comparison: (a: Int, b: Int, versions: (ReplyVersion, ReplyVersion))? {
        let list = allVersions.list
        for j in list.indices.reversed() {
            guard let id = list[j].metrics?.compareID else { continue }
            if let i = list[..<j].lastIndex(where: { $0.metrics?.compareID == id }) {
                return (i, j, (list[i], list[j]))
            }
        }
        return nil
    }

    /// Changes the metrics of answer `index` of `allVersions`, wherever it's kept (this message or
    /// one of `versions`).
    mutating func updateMetrics(ofVersion index: Int, _ change: (inout ReplyMetrics?) -> Void) {
        let current = allVersions.current
        if index == current { return change(&metrics) }
        let i = index < current ? index : index - 1
        guard versions?.indices.contains(i) == true else { return }
        change(&versions![i].metrics)
    }
}

extension Conversation {
    /// The model that wrote an answer: from its metrics; for one from before them, from the model
    /// named in its footnote ("Gemma 4 E2B", "Inkling 2 Mini on your Mac"), matched against the
    /// on-device models and `macModels` (Ollama's names); else the chat's own model.
    func model(of metrics: ReplyMetrics?, footnote: String?, macModels: [String]) -> ModelChoice {
        if let metrics, let mode = Mode(rawValue: metrics.modeRaw) {
            return ModelChoice(mode: mode, macModel: mode == .mac ? metrics.macModel : nil)
        }
        if let name = ChatSearch.modelName(footnote) {
            if let mode = Mode.allCases.first(where: { $0.isOnDevice && $0.title == name }) {
                return ModelChoice(mode: mode, macModel: nil)
            }
            let suffix = " on your Mac"
            let macName = name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
            if let model = ([resolvedMacModel] + macModels).first(where: { !$0.isEmpty && MacLink.displayName($0) == macName }) {
                return ModelChoice(mode: .mac, macModel: model)
            }
        }
        return ModelChoice(mode: mode, macModel: mode == .mac ? resolvedMacModel : nil)
    }
}

/// A model to answer with: an on-device mode, or the Mac with one of its Ollama models.
struct ModelChoice: Hashable, Sendable {
    let mode: Mode
    /// For `.mac`, which Ollama model; nil means the chat's (or the Mac's default).
    let macModel: String?

    nonisolated var title: String { macModel.map(MacLink.displayName) ?? mode.title }
}

/// How one reply was made and how fast, kept on the reply (and its versions) for the info panel,
/// comparisons and per-model averages. Everything is optional: what a route can't measure is nil.
/// Times are seconds. Codable and additive: saved with the messages, never renamed.
nonisolated struct ReplyMetrics: Codable, Hashable, Sendable {
    /// `Mode` raw value of the model that answered.
    var modeRaw: String
    /// For the Mac: the Ollama model name.
    var macModel: String?
    /// The display name, as shown then ("Gemma 4 E4B", "Inkling 2 Mini").
    var modelTitle: String
    /// Shared by the two answers of one comparison.
    var compareID: UUID?
    /// The user's vote in a comparison: true for this answer.
    var preferred: Bool?

    /// Loading the model before the reply could start (on device, or Ollama's load on the Mac).
    /// About 0 when it was already loaded. Never included in the first-token times or tokens/s.
    var loadSeconds: Double?
    /// From the request to the first token of thinking or answer, less `loadSeconds`. On the Mac
    /// it includes finding the Mac, connecting and Ollama reading the prompt (not its load).
    var firstTokenSeconds: Double?
    /// From the request to the first token of the answer itself (after any thinking), less
    /// `loadSeconds`.
    var firstAnswerSeconds: Double?
    /// Reading the prompt (prefill). On device `promptTokens` is the whole prompt, `reusedTokens`
    /// of it already in the cache; on the Mac it's what Ollama evaluated (its cache excluded) and
    /// `reusedTokens` is nil.
    var promptTokens: Int?
    var reusedTokens: Int?
    var promptSeconds: Double?
    /// Continued a saved state (on device).
    var restored: Bool?
    /// Generated tokens (thinking included) and the time spent generating them.
    var generatedTokens: Int?
    var generateSeconds: Double?
    var tokensPerSecond: Double?
    /// On device with an MTP drafter (Gemma): tokens it guessed, and how many the model kept.
    var draftedTokens: Int?
    var acceptedDraftTokens: Int?
    /// From the request to the last token, everything included (load too).
    var totalSeconds: Double?

    /// Mac only: finding the Mac, connecting, and the route ("Home network", "Tailnet").
    var findSeconds: Double?
    var connectSeconds: Double?
    var route: String?
    /// Mac only: Ollama's own `total_duration` (load, read and generate on the Mac, no network).
    var serverSeconds: Double?

    /// Asked to think (or the model always thinks).
    var thinking: Bool?

    /// The model, with "· Thinking" when it thought: what tells apart the two answers of a
    /// comparison of one model with thinking on and off.
    var labeledTitle: String {
        thinking == true && modeRaw != Mode.apple.rawValue ? "\(modelTitle) · Thinking" : modelTitle
    }
    /// The oldest turns were left out to fit the context.
    var trimmed: Bool?
    /// Cut off by a limit (`StopReason` raw value) or stopped by the user.
    var cutOff: String?
    var stopped: Bool?
}

/// What went wrong with a reply, so the chat can offer something better than the message alone.
nonisolated enum ReplyErrorKind: String, Codable, Sendable {
    /// The mode's model isn't on this device: offer Readiness.
    case notDownloaded
    /// The model file was being converted (Inkling, in earlier builds). Kept so saved replies decode.
    case modelBusy
    /// The model couldn't be loaded (usually memory).
    case loadFailed
    /// The chat no longer fits the model's context: offer `Engine.continueTrimmed(in:)` or
    /// `Engine.continueInNewChat(from:)`.
    case contextFull
    /// Ollama on the Mac didn't answer on either route: offer the on-device models.
    case macUnreachable
    /// Ollama answered but has no usable model (none at all, or the chosen one is gone).
    case macNoModel
    /// Ollama answered with an error.
    case macFailed
    case other
}
