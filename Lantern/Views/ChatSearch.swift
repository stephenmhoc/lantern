import Foundation
import Observation
import SwiftData
import SwiftUI

/// Which part of the chats the sidebar's search looks in (its scope bar while searching).
nonisolated enum SearchScope: String, CaseIterable, Hashable, Sendable {
    case all, questions, answers

    func includes(_ field: ChatSearch.Field) -> Bool {
        switch self {
        case .all: true
        case .questions: field.isQuestion
        case .answers: !field.isQuestion
        }
    }

    var title: String {
        switch self {
        case .all: "All"
        case .questions: "Questions"
        case .answers: "Answers"
        }
    }
}

/// History search for the sidebar. Chats keep their messages as one Codable blob, so this is an
/// in-memory scan: `documents` copies what's searchable out of the chats on the main actor (plain
/// strings, shared rather than copied), then `run` matches and builds snippets off it.
///
/// What it looks in, best first within a chat: the question or answer as shown, a file's name, a
/// file's extracted text, the other answers to the same question (Retry, comparisons), and last the
/// model's thinking. Thinking is cheap to scan (one more string) and its results say so ("…,
/// thinking"); a chat found only there still sorts after one found in what was said.
/// Matching is case-, diacritic- and width-insensitive, like `localizedStandardContains`.
nonisolated enum ChatSearch {
    static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    // MARK: Input

    /// One chat's searchable text, safe to hand to a background task.
    struct Document: Sendable {
        let id: PersistentIdentifier
        let title: String
        let lastActive: Date
        let fields: [Field]
        /// The last thing said, for a chat found only by its title.
        let lastText: String?
    }

    /// One searchable string in a chat.
    struct Field: Sendable {
        let message: UUID
        /// Position in the chat, for preferring the latest of equally good matches.
        let index: Int
        let kind: Kind
        /// In a question (its text or files) rather than an answer, for the scopes.
        let isQuestion: Bool
        /// For `.otherAnswer`, which of `StoredMessage.allVersions` it is.
        let version: Int?
        let text: String
        /// Shown before the snippet: "You", "Gemma 4 E2B", "report.pdf".
        let speaker: String
        /// Read by VoiceOver before the snippet: "you said", "Gemma 4 E2B said", "in report.pdf".
        let spoken: String
    }

    /// Best first.
    enum Kind: Int, Sendable, Comparable {
        case said, fileName, fileText, otherAnswer, thinking

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    @MainActor
    static func documents(_ chats: [Conversation]) -> [Document] {
        chats.compactMap { c in
            guard c.modelContext != nil, !c.isDeleted else { return nil }
            let chatModel = c.modelTitle
            var fields: [Field] = []
            for (i, m) in c.messages.enumerated() {
                if m.isUser {
                    if !m.content.isEmpty {
                        fields.append(Field(message: m.id, index: i, kind: .said, isQuestion: true, version: nil, text: m.content,
                                            speaker: "You", spoken: "you said"))
                    }
                    for file in m.attachments ?? [] {
                        fields.append(Field(message: m.id, index: i, kind: .fileName, isQuestion: true, version: nil, text: file.name,
                                            speaker: "You attached", spoken: "you attached"))
                        if !file.text.isEmpty {
                            fields.append(Field(message: m.id, index: i, kind: .fileText, isQuestion: true, version: nil, text: file.text,
                                                speaker: file.name, spoken: "in \(file.name)"))
                        }
                    }
                } else {
                    let model = m.metrics?.modelTitle ?? modelName(m.footnote) ?? chatModel
                    if !m.content.isEmpty {
                        fields.append(Field(message: m.id, index: i, kind: .said, isQuestion: false, version: nil, text: m.content,
                                            speaker: model, spoken: "\(model) said"))
                    }
                    if !m.thinking.isEmpty {
                        fields.append(Field(message: m.id, index: i, kind: .thinking, isQuestion: false, version: nil, text: m.thinking,
                                            speaker: "\(model), thinking", spoken: "\(model) thought"))
                    }
                    guard let others = m.versions, !others.isEmpty else { continue }
                    let (list, current) = m.allVersions
                    for (v, version) in list.enumerated() where v != current && !version.content.isEmpty {
                        let other = version.metrics?.modelTitle ?? modelName(version.footnote) ?? model
                        fields.append(Field(message: m.id, index: i, kind: .otherAnswer, isQuestion: false, version: v, text: version.content,
                                            speaker: "\(other), another answer", spoken: "\(other) said, in another answer"))
                    }
                }
            }
            return Document(id: c.persistentModelID, title: c.title, lastActive: c.lastActive, fields: fields,
                            lastText: c.messages.last(where: { !$0.content.isEmpty })?.content)
        }
    }

    /// "Gemma 4 E2B" from "Gemma 4 E2B · 14.2 tok/s" (or "Stopped · Gemma 4 E2B · …"), for
    /// replies saved before `ReplyMetrics`.
    static func modelName(_ footnote: String?) -> String? {
        guard let name = footnote?.components(separatedBy: " · ").first(where: { !$0.hasPrefix("Stopped") }),
              !name.isEmpty, !name.contains("tok/s"), !name.contains("first token") else { return nil }
        return name
    }

    // MARK: Output

    struct Hit: Sendable, Identifiable {
        let id: String
        let message: UUID
        let version: Int?
        let kind: Kind
        /// Speaker, then the snippet with the match in bold and tinted.
        let line: AttributedString
        /// The same for VoiceOver: "you said: …snippet…".
        let spoken: String
    }

    struct Result: Sendable, Identifiable {
        let id: PersistentIdentifier
        let titleMatch: Bool
        let title: AttributedString
        let plainTitle: String
        let lastActive: Date
        /// The best one or two matches in the chat.
        let hits: [Hit]
        /// How many other places in the chat match.
        let more: Int
        /// The last thing said, shown when only the title matched.
        let preview: String?

        /// Where tapping the result should scroll the chat to.
        var target: Hit? { hits.first }
    }

    /// `run` off the main actor, cancelled with the caller (typing on cancels the last search).
    @concurrent
    static func search(_ documents: [Document], query: String, scope: SearchScope) async -> [Result] {
        run(documents, query: query, scope: scope)
    }

    /// Matches `query` in `documents`: chats whose title matches first, then by `lastActive`
    /// (`documents` are already newest first, and the sort is stable).
    ///
    /// The scan is over `SearchIndex`'s folded bytes with `memmem` (a chat is folded once per
    /// version of it, then reused); only the one or two hits shown are located in the original
    /// text with `range(of:options:)`, which is far slower per character.
    static func run(_ documents: [Document], query raw: String, scope: SearchScope) -> [Result] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let needle = SearchIndex.fold(query)
        let index = SearchIndex.shared
        var titled: [Result] = [], others: [Result] = []
        for doc in documents {
            if Task.isCancelled { return [] }
            let entry = index.entry(for: doc)
            // The title is neither a question nor an answer: it counts only in All.
            let titleMatch = scope == .all && SearchIndex.contains(entry.title, needle)
            var found: [(offset: Int, field: Field)] = []
            for (i, field) in doc.fields.enumerated() where scope.includes(field) {
                if SearchIndex.contains(entry.fields[i], needle) { found.append((i, field)) }
            }
            guard titleMatch || !found.isEmpty else { continue }
            // Best kind first, then the latest message.
            found.sort { a, b in a.field.kind != b.field.kind ? a.field.kind < b.field.kind : a.field.index > b.field.index }
            let shown = found.prefix(2).map { f in
                hit(query: query, field: f.field, offset: f.offset, range: f.field.text.range(of: query, options: compareOptions))
            }
            let result = Result(
                id: doc.id,
                titleMatch: titleMatch,
                title: highlighted(doc.title, query: query),
                plainTitle: doc.title,
                lastActive: doc.lastActive,
                hits: shown,
                more: found.count - shown.count,
                preview: shown.isEmpty ? doc.lastText.map { String(flatten(Substring($0.prefix(400))).prefix(160)) } : nil
            )
            if titleMatch { titled.append(result) } else { others.append(result) }
        }
        index.prune(keeping: Set(documents.map(\.id)))
        return titled + others
    }

    /// `offset`: the field's position in its document, which makes the hit's id unique.
    private static func hit(query: String, field: Field, offset: Int, range found: Range<String.Index>?) -> Hit {
        let text = field.text
        // Folding and `range(of:options:)` can disagree on a rare character: then the start.
        let range = found ?? text.startIndex..<text.startIndex
        // A window around the match, flattened to one line, then cut to a little before it.
        let lower = text.index(range.lowerBound, offsetBy: -120, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = flatten(text[lower..<upper])
        var cut = lower > text.startIndex
        if let m = snippet.range(of: query, options: compareOptions) {
            let lead = snippet.distance(from: snippet.startIndex, to: m.lowerBound)
            if lead > 36 {
                // Start at a word: the first space in the 36 characters before the match.
                let from = snippet.index(m.lowerBound, offsetBy: -36)
                let start = snippet[from..<m.lowerBound].firstIndex(of: " ").map { snippet.index(after: $0) } ?? from
                snippet = String(snippet[start...])
                cut = true
            }
        }
        if cut { snippet = "…" + snippet }
        var line = AttributedString(field.speaker + "  ")
        line.inlinePresentationIntent = .stronglyEmphasized
        line.foregroundColor = Color.primary
        line += highlighted(snippet, query: query)
        let id = "\(field.message)-\(offset)"
        return Hit(id: id, message: field.message, version: field.version, kind: field.kind, line: line,
                   spoken: "\(field.spoken): \(snippet)")
    }

    /// `text` with each occurrence of `query` in bold, on a faint tint of the accent colour. The
    /// text stays the primary colour: the amber itself as text is about 2.3:1 on white.
    /// The accent at a strength that shows on black as well as white, stronger with Increase Contrast.
    static let matchTint = Color(UIColor { traits in
        let high = traits.accessibilityContrast == .high
        let alpha: CGFloat = traits.userInterfaceStyle == .dark ? (high ? 0.45 : 0.32) : (high ? 0.32 : 0.22)
        let accent = UIColor(named: "AccentColor")?.resolvedColor(with: traits) ?? .systemOrange
        return accent.withAlphaComponent(alpha)
    })

    static func highlighted(_ text: String, query: String) -> AttributedString {
        var out = AttributedString()
        var rest = text[...]
        while let r = rest.range(of: query, options: compareOptions), !r.isEmpty {
            out += AttributedString(String(rest[..<r.lowerBound]))
            var match = AttributedString(String(rest[r]))
            match.inlinePresentationIntent = .stronglyEmphasized
            match.foregroundColor = Color.primary
            match.backgroundColor = Self.matchTint
            out += match
            rest = rest[r.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
    }

    /// One line: no line breaks, runs of spaces or the commonest Markdown marks.
    static func flatten(_ text: Substring) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var space = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop { "#>*-` \t".contains($0) }
            for ch in trimmed {
                if ch == " " || ch == "\t" {
                    space = !out.isEmpty
                } else if ch == "*" || ch == "`" {
                    continue
                } else {
                    if space { out.append(" "); space = false }
                    out.append(ch)
                }
            }
            space = !out.isEmpty
        }
        return out
    }

    /// Whether a chat matches anywhere `run` looks (for `ChatSection.filter`'s other callers).
    @MainActor
    static func matches(_ c: Conversation, query: String) -> Bool {
        if c.title.range(of: query, options: compareOptions) != nil { return true }
        return documents([c]).first?.fields.contains { $0.text.range(of: query, options: compareOptions) != nil } ?? false
    }
}

/// The chats' searchable text folded (case, diacritics, width) to UTF-8 bytes, kept between
/// searches and refolded only for a chat whose text changed. Used from one search at a time, but
/// a cancelled one may still be finishing, hence the lock.
nonisolated final class SearchIndex: @unchecked Sendable {
    static let shared = SearchIndex()

    struct Entry {
        let signature: Int
        let title: [UInt8]
        let fields: [[UInt8]]
    }

    private let lock = NSLock()
    private var entries: [PersistentIdentifier: Entry] = [:]

    func entry(for doc: ChatSearch.Document) -> Entry {
        // The text itself, not just its length: an edit that keeps the length must be refolded.
        // Hashing is far cheaper than folding.
        var h = Hasher()
        h.combine(doc.title)
        h.combine(doc.fields.count)
        for f in doc.fields { h.combine(f.text); h.combine(f.kind) }
        let signature = h.finalize()
        if let cached = lock.withLock({ entries[doc.id] }), cached.signature == signature { return cached }
        let entry = Entry(signature: signature, title: Self.fold(doc.title), fields: doc.fields.map { Self.fold($0.text) })
        lock.withLock { entries[doc.id] = entry }
        return entry
    }

    /// Drops every chat's folded text: when the search ends, or memory runs low.
    func clear() {
        lock.withLock { entries = [:] }
    }

    func prune(keeping ids: Set<PersistentIdentifier>) {
        lock.withLock { entries = entries.filter { ids.contains($0.key) } }
    }

    static func fold(_ text: String) -> [UInt8] {
        Array(text.folding(options: ChatSearch.compareOptions, locale: nil).utf8)
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return needle.isEmpty }
        return haystack.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
        }
    }
}

// MARK: - Jumping to a match

/// The message a search result points at, for the chat screen to scroll to once it shows that chat.
/// Set when a result is tapped, just before the chat is selected; the chat screen takes it with
/// `claim(for:)`, so it's used once and only by the window showing that chat. Shared by every
/// window, so requests are kept per chat: one window clearing its own never drops another's.
@Observable
final class ChatJump {
    static let shared = ChatJump()

    struct Target: Equatable, Sendable {
        let conversation: PersistentIdentifier
        let message: UUID
        /// The matching answer when it's one of `StoredMessage.allVersions` other than the one shown.
        let version: Int?
        /// What was searched for, to highlight in the message if the screen wants to.
        let query: String
    }

    private(set) var pending: [PersistentIdentifier: Target] = [:]

    func request(_ target: Target) { pending[target.conversation] = target }

    /// The target for this chat, cleared once taken. Nil if there's none for it.
    func claim(for conversation: PersistentIdentifier) -> Target? {
        pending.removeValue(forKey: conversation)
    }

    func clear(for conversation: PersistentIdentifier) { pending[conversation] = nil }
}

// MARK: - Row

/// One search result in the sidebar: the chat's title and date, then the best match or two, each
/// with who said it, and how many more places match.
struct SearchResultRow: View {
    let result: ChatSearch.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(result.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                Text(ChatRow.when(result.lastActive)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(result.hits) { hit in
                Text(hit.line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if result.hits.isEmpty, let preview = result.preview {
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if result.more > 0 {
                Text(result.more == 1 ? "1 more match" : "\(result.more) more matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isButton)
    }

    /// "Sourdough starter schedule, you said: …feed it twice a day…, 3 more matches, Yesterday".
    private var spoken: String {
        var parts = [result.plainTitle]
        parts += result.hits.map(\.spoken)
        if result.more > 0 { parts.append(result.more == 1 ? "1 more match" : "\(result.more) more matches") }
        parts.append(result.lastActive.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
extension ChatSearch {
    /// `-searchBench`: 300 made-up chats of 40 messages (short questions, ~2,500-character answers)
    /// in an in-memory store; prints how long copying them out (main actor) and searching take.
    static func benchmark() {
        guard ProcessInfo.processInfo.arguments.contains("-searchBench") else { return }
        Task { @MainActor in
            let words = ["starter", "flour", "water", "heat", "pump", "résumé", "café", "Fourier", "signal", "frequency",
                         "the", "and", "a", "of", "to", "in", "is", "that", "it", "for", "with", "as", "on", "be"]
            func paragraph(_ n: Int) -> String { (0..<n).map { _ in words.randomElement()! }.joined(separator: " ") }
            let container = try! ModelContainer(for: Conversation.self, configurations: .init(isStoredInMemoryOnly: true))
            let context = container.mainContext
            for c in 0..<300 {
                let chat = Conversation(mode: .fast)
                chat.title = "Chat \(c) " + paragraph(4)
                chat.messages = (0..<40).map { i in StoredMessage(isUser: i % 2 == 0, content: paragraph(i % 2 == 0 ? 40 : 400)) }
                context.insert(chat)
            }
            try? context.save()
            let chats = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
            var start = ContinuousClock.now
            let docs = documents(chats)
            let chars = docs.reduce(0) { $0 + $1.fields.reduce(0) { $0 + $1.text.count } }
            print("SEARCHBENCH documents: \(docs.count) chats, \(chars) characters, in \(ContinuousClock.now - start)")
            for q in ["cafe", "cafe", "fourier sig", "zzz", "Résumé the"] {
                start = ContinuousClock.now
                let results = await search(docs, query: q, scope: .all)
                print("SEARCHBENCH \(q): \(results.count) chats in \(ContinuousClock.now - start)")
            }
        }
    }
}
#endif
