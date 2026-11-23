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

    init(mode: Mode) { self.mode = mode }

    /// What the model sees before message `index`: user turns and answers, including a stopped
    /// answer's partial text, but not failed or empty replies.
    func history(before index: Int) -> [ChatMessage] {
        messages[..<index].compactMap { m in
            guard m.error == nil, !m.content.isEmpty else { return nil }
            return ChatMessage(role: m.isUser ? .user : .assistant, content: m.content)
        }
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
    /// The other answers to the same question (from Retry), oldest first. Optional so messages saved
    /// before it existed still decode.
    var versions: [ReplyVersion]?
    /// Where this answer sits among `versions`, oldest first; nil means it's the newest.
    var versionIndex: Int?
    /// How long the model thought before answering, when the chat screen saw it happen.
    var thoughtSeconds: Double?

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
