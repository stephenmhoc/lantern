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
    /// This device's model or the Mac. Which on-device model is never the chat's business: it's
    /// whatever the device it's open on runs (`CatalogModel.device`), so a chat can be continued
    /// on any device. Each reply records the model that wrote it (`ReplyMetrics`).
    var mode: Mode = Mode.device
    /// For the Mac, which of its models answers ("inkling2:mini"). Empty means the Mac's usual
    /// one (`MacLink.modelKey`); the first reply fixes it.
    var macModel: String = ""
    var thinking: Thinking = Thinking.off
    /// Whether the model may search the web while answering in this chat (the picker's switch,
    /// beside Think First). It only happens with a Tavily key in Settings.
    var webSearch: Bool = false
    /// Never used any more (chats could be pinned). Kept so existing stores open.
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

    /// Chats from when there were several on-device models (`fast`, `smart`, `qwen`, `apple`) now
    /// use this device's. And searching the web was one switch in Settings before each chat had
    /// its own: if it was on, existing chats keep searching (their system turns declared the tool,
    /// so their saved states stay valid) and new chats start with it on. Run at launch.
    static func repairModes(in context: ModelContext) {
        let chats = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        let defaults = UserDefaults.standard
        let searched = defaults.bool(forKey: ChatDefaults.oldSearchKey)
        var changed = false
        for c in chats {
            if c.mode != c.mode.current { c.mode = c.mode.current; changed = true }
            if searched, !c.webSearch { c.webSearch = true; changed = true }
        }
        if searched {
            defaults.set(true, forKey: ChatDefaults.searchKey)
            defaults.removeObject(forKey: ChatDefaults.oldSearchKey)
        }
        if changed { try? context.save() }
    }

    init(mode: Mode) {
        self.mode = mode
        self.thinking = ChatDefaults.thinking
        self.webSearch = ChatDefaults.webSearch
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

    /// The model this chat uses on the Mac (its id, as the bridge lists it).
    var resolvedMacModel: String {
        macModel.isEmpty ? UserDefaults.standard.string(forKey: MacLink.modelKey) ?? "" : macModel
    }

    /// Where the next answer comes from. A chat set to the Mac answers on this device while no
    /// Mac is paired (it was unpaired, or the chat came from another device): an unpaired Mac is
    /// never what's selected. On a Mac every chat is answered by a Mac's model: it has none of
    /// its own (`Device.isMac`).
    @MainActor var answeringMode: Mode { Device.isMac || (mode == .mac && MacLink.isConfigured) ? .mac : .device }

    /// What answers next, by name: "Gemma 4 E4B", "Inkling 2 Mini" ("Mac" until the Mac has named its model).
    @MainActor var modelTitle: String {
        guard answeringMode == .mac else { return ModelStore.shared.model.name }
        return resolvedMacModel.isEmpty ? "Mac" : MacLink.displayName(resolvedMacModel)
    }
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
    /// The web searches the model ran for this answer, in order. Nil for none, and for replies
    /// from before searching existed.
    var searches: [WebSearch]?

    nonisolated var hasAttachments: Bool { !(attachments ?? []).isEmpty }

    /// This turn as the model sees it, or nil if it isn't sent (failed or empty). A question's text
    /// is preceded by its date note and its files' text, in a fixed format, so the turn renders
    /// byte for byte the same each time (a saved cache is only reused for an identical prefix).
    nonisolated var chatMessage: ChatMessage? {
        guard error == nil, !content.isEmpty || hasAttachments else { return nil }
        guard isUser else { return ChatMessage(role: .assistant, content: content, searches: searches ?? []) }
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
        searches = chosen.searches
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
    var searches: [WebSearch]?

    init(_ m: StoredMessage) {
        content = m.content
        thinking = m.thinking
        footnote = m.footnote
        error = m.error
        thoughtSeconds = m.thoughtSeconds
        metrics = m.metrics
        searches = m.searches
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

/// A model to answer with: this device's, or the Mac with one of its models.
struct ModelChoice: Hashable, Sendable {
    let mode: Mode
    /// For `.mac`, which of its models; nil means the chat's (or the Mac's usual one).
    let macModel: String?

    static let device = ModelChoice(mode: .device, macModel: nil)

    @MainActor var title: String { macModel.map(MacLink.displayName) ?? (mode == .mac ? "Mac" : ModelStore.shared.model.name) }
}

/// Which model wrote a reply and how, kept on the reply (and its versions). Codable and additive:
/// saved with the messages, never renamed. The timings and token counts below "No longer
/// recorded" were shown by earlier versions; they stay so stored replies decode as they are.
nonisolated struct ReplyMetrics: Codable, Hashable, Sendable {
    /// `Mode` raw value of where it ran: `mac`, or anything else for the device it was sent from.
    var modeRaw: String
    /// For the Mac: the model's id, as the bridge lists it.
    var macModel: String?
    /// The display name, as shown then ("Gemma 4 E4B", "Inkling 2 Mini").
    var modelTitle: String
    /// Shared by the two answers of one comparison.
    var compareID: UUID?
    /// The user's vote in a comparison: true for this answer.
    var preferred: Bool?

    /// Asked to think (or the model always thinks).
    var thinking: Bool?
    /// The oldest turns were left out to fit the context.
    var trimmed: Bool?
    /// Cut off by a limit (`StopReason` raw value) or stopped by the user.
    var cutOff: String?
    var stopped: Bool?

    /// The model, with "· Thinking" when it thought: what tells apart the two answers of a
    /// comparison of one model with thinking on and off.
    var labeledTitle: String { thinking == true ? "\(modelTitle) · Thinking" : modelTitle }

    // MARK: No longer recorded

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
}

/// What went wrong with a reply, so the chat can offer something better than the message alone.
nonisolated enum ReplyErrorKind: String, Codable, Sendable {
    /// This device's model isn't downloaded: offer to get it.
    case notDownloaded
    /// The model file was being converted (Inkling, in earlier builds). Kept so saved replies decode.
    case modelBusy
    /// The model couldn't be loaded (usually memory).
    case loadFailed
    /// The chat no longer fits the model's context: offer `Engine.continueTrimmed(in:)` or
    /// `Engine.continueInNewChat(from:)`.
    case contextFull
    /// The Mac didn't answer on either route: offer this device's model.
    case macUnreachable
    /// The Mac answered but has no usable model (none at all, or the chosen one is gone).
    case macNoModel
    /// The Mac answered with an error.
    case macFailed
    case other
}
