import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A chat's title. It starts as the first question (`provisional`); after the first answer, Apple
/// Intelligence's on-device model, when it's on, sums the chat up in a few words. A title the user
/// typed is never replaced: only one still equal to the question (as this or an older version set
/// it) counts as automatic. Without Apple Intelligence the title stays the question.
@MainActor
final class ChatTitler {
    static let shared = ChatTitler()

    private var queue: [Conversation] = []
    private var working = false
    private var backfilled = false

    /// The title a chat gets when its first question is sent.
    static func provisional(text: String, attachments: [Attachment]) -> String {
        let source = text.isEmpty ? attachments.first?.name ?? "New chat" : text
        let flat = source.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(flat.prefix(200))
    }

    /// Whether `c` still has the title it was given automatically. Before this, titles were the
    /// question's first 60 characters, newlines and all.
    static func hasAutomaticTitle(_ c: Conversation) -> Bool {
        guard let first = c.messages.first(where: \.isUser) else { return false }
        let attachments = first.attachments ?? []
        let old = String((first.content.isEmpty ? attachments.first?.name ?? "" : first.content).prefix(60))
        return c.title == provisional(text: first.content, attachments: attachments) || c.title == old
    }

    /// After an answer: titles the chat if it still has its automatic title.
    func titleIfNeeded(_ c: Conversation) {
        guard AppleStatus.current.isAvailable, Self.hasAutomaticTitle(c),
              c.messages.contains(where: { !$0.isUser && !$0.content.isEmpty }) else { return }
        enqueue(c)
    }

    /// Once a launch: titles the recent chats that still have their question as the title.
    func backfill(_ chats: [Conversation]) {
        guard !backfilled, AppleStatus.current.isAvailable else { return }
        backfilled = true
        for c in chats.prefix(40) where Self.hasAutomaticTitle(c) && c.messages.contains(where: { !$0.isUser && !$0.content.isEmpty }) {
            enqueue(c)
        }
    }

    private func enqueue(_ c: Conversation) {
        guard !queue.contains(where: { $0 === c }) else { return }
        queue.append(c)
        guard !working else { return }
        working = true
        Task {
            while !queue.isEmpty {
                let c = queue.removeFirst()
                guard c.modelContext != nil, !c.isDeleted, Self.hasAutomaticTitle(c) else { continue }
                let excerpt = Self.excerpt(c)
                guard let title = await Self.summarize(excerpt) else { continue }
                // The user may have renamed it, or deleted it, while the model was thinking.
                guard c.modelContext != nil, !c.isDeleted, Self.hasAutomaticTitle(c) else { continue }
                c.title = title
                try? c.modelContext?.save()
            }
            working = false
        }
    }

    /// The first question and answer, cut short: enough to know what the chat is about.
    private static func excerpt(_ c: Conversation) -> String {
        let question = c.messages.first(where: \.isUser)
        let answer = c.messages.first(where: { !$0.isUser && !$0.content.isEmpty })
        var q = String((question?.content ?? "").prefix(800))
        if q.isEmpty { q = (question?.attachments ?? []).map(\.name).joined(separator: ", ") }
        let a = String((answer?.content ?? "").prefix(800))
        return "Question:\n\(q)\n\nAnswer:\n\(a)"
    }

    nonisolated static func summarize(_ excerpt: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26, *) else { return nil }
        let session = LanguageModelSession(model: .default, instructions: """
            You name chats. Given the start of a chat, reply with a title of two to five words that \
            says what it is about, like the title of a note. Reply with the title only: no quotes, \
            no full stop, no "Title:".
            """)
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 24)
        guard let response = try? await session.respond(to: excerpt, options: options) else { return nil }
        return clean(response.content)
        #else
        return nil
        #endif
    }

    /// The first line, without quotes, a label or a full stop; nil if nothing usable is left.
    nonisolated static func clean(_ raw: String) -> String? {
        var t = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst(6)) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*#. ").union(.whitespaces))
        guard !t.isEmpty, t.count <= 60, t.split(separator: " ").count <= 8 else { return nil }
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}
