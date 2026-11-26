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

    /// The first question, cut short. The answer is left out: given it, the model titled the reply
    /// ("Sky blue due to Rayleigh scattering") instead of the question ("Why the sky is blue").
    private static func excerpt(_ c: Conversation) -> String {
        let question = c.messages.first(where: \.isUser)
        var q = String((question?.content ?? "").prefix(800))
        if q.isEmpty { q = (question?.attachments ?? []).map(\.name).joined(separator: ", ") }
        // Framed as something to label, or the model answers it (a translation request came back translated).
        return "Label this chat. Its first message:\n\"\"\"\n\(q)\n\"\"\""
    }

    /// Tuned against the on-device model: examples did far more than rules (without them titles were
    /// vague, like "Winter Vehicle Choice" for Subaru Outback vs RAV4, and in Title Case).
    private nonisolated static let instructions = """
        You write the short label shown for a chat in a list of past chats, so the person can find it \
        again. You never answer the question or do what it asks: you only label it.

        Rules:
        - Two to five words. Capitalize the first word; keep names, acronyms, months and languages as \
        they are normally written (TCP, March, Japanese).
        - Name the specific subject, keeping the key words the person used: names, places, products, \
        languages, technologies.
        - Say what the chat is about, not what the reply said. No filler like "question about", \
        "help with", "request for".
        - Write the label in the language of the first message.
        - Reply with the label alone: no quotes, no full stop.

        Examples:
        how long do eggs keep outside the fridge → Eggs outside the fridge
        Compare the iPhone 16 and Pixel 9 cameras → iPhone 16 vs Pixel 9 cameras
        write a bash script that renames all my jpgs by date → Bash script to rename JPGs by date
        translate "thank you very much" into French → "Thank you very much" in French
        why is the ocean salty → Why the ocean is salty
        make this sound friendlier: per my last email, please advise → Friendlier email wording
        plan a week of vegetarian dinners for two → Vegetarian dinner plan
        hey there → Greeting
        """

    nonisolated static func summarize(_ excerpt: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else { return nil }
        let session = LanguageModelSession(model: .default, instructions: instructions)
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
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "*#. ").union(.whitespaces))
        // Quotes only when they wrap the whole title: a quoted phrase inside one ("Thank you" in French) stays.
        let quotes = CharacterSet(charactersIn: "\"'“”‘’")
        if let f = t.unicodeScalars.first, let l = t.unicodeScalars.last, quotes.contains(f), quotes.contains(l),
           t.dropFirst().dropLast().allSatisfy({ !"\"“”".contains($0) }) {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !t.isEmpty, t.count <= 60, t.split(separator: " ").count <= 8 else { return nil }
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}
