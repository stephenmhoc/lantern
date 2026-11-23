import Foundation
import LlamaKit
import SwiftData

@Model
final class Conversation {
    var title: String = "New chat"
    var created: Date = Date()
    var updated: Date = Date()
    var mode: Mode = Mode.fast
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
}

struct StoredMessage: Codable, Hashable, Identifiable {
    var id = UUID()
    var isUser: Bool
    var content = ""
    var thinking = ""
    /// Which model wrote it and how fast, e.g. "Inkling 2 Mini (Q2_K_XL) · 4.1 tok/s".
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

    nonisolated var hasAttachments: Bool { !(attachments ?? []).isEmpty }

    /// This turn as the model sees it, or nil if it isn't sent (failed or empty). A question's text
    /// is preceded by its date note and its files' text, in a fixed format, so the turn renders
    /// byte for byte the same each time (Inkling's cache is only ever appended to).
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

    init(_ m: StoredMessage) {
        content = m.content
        thinking = m.thinking
        footnote = m.footnote
        error = m.error
        thoughtSeconds = m.thoughtSeconds
    }
}

/// What went wrong with a reply, so the chat can offer something better than the message alone.
nonisolated enum ReplyErrorKind: String, Codable, Sendable {
    /// The mode's model isn't on this device: offer Readiness.
    case notDownloaded
    /// The model file is being converted: try again shortly.
    case modelBusy
    /// The model couldn't be loaded (usually memory).
    case loadFailed
    /// The chat no longer fits the model's context: offer `Engine.continueTrimmed(in:)` or
    /// `Engine.continueInNewChat(from:)`.
    case contextFull
    /// Ollama on the Mac didn't answer on either route: offer Fast or Smart.
    case macUnreachable
    /// Ollama answered but has no usable model (none at all, or the chosen one is gone).
    case macNoModel
    /// Ollama answered with an error.
    case macFailed
    case other
}
