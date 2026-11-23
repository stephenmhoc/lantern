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
}
