import Foundation
import LlamaKit
import SwiftData
import SwiftUI

/// A group of chats in the sidebar: Pinned, then by when they were last used.
struct ChatSection: Identifiable {
    let title: String
    let chats: [Conversation]
    var id: String { title }

    /// `chats` must already be sorted newest first.
    static func group(_ chats: [Conversation], now: Date = .now, calendar: Calendar = .current) -> [ChatSection] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var pinned: [Conversation] = [], todays: [Conversation] = [], yesterdays: [Conversation] = []
        var weeks: [Conversation] = [], older: [Conversation] = []
        for c in chats {
            if c.pinned { pinned.append(c) }
            else if c.lastActive >= today { todays.append(c) }
            else if c.lastActive >= yesterday { yesterdays.append(c) }
            else if c.lastActive >= week { weeks.append(c) }
            else { older.append(c) }
        }
        return [
            ChatSection(title: "Pinned", chats: pinned),
            ChatSection(title: "Today", chats: todays),
            ChatSection(title: "Yesterday", chats: yesterdays),
            ChatSection(title: "Previous 7 Days", chats: weeks),
            ChatSection(title: "Older", chats: older),
        ].filter { !$0.chats.isEmpty }
    }

    /// In-memory search over titles and message text.
    static func filter(_ chats: [Conversation], query: String) -> [Conversation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return chats }
        return chats.filter { c in
            c.title.localizedStandardContains(q) || c.messages.contains { $0.content.localizedStandardContains(q) }
        }
    }
}

/// The mode a new chat starts in: the last one used if it works right now, else the quickest that
/// does (the Mac if it answers, then Gemma 4 E2B, then E4B).
enum DefaultMode {
    static let key = "chat.lastMode"

    static func pick(last: String, engine: Engine) -> Mode {
        if let last = Mode(rawValue: last), isAvailable(last, engine: engine) { return last }
        return [Mode.mac, .fast, .smart].first { isAvailable($0, engine: engine) } ?? .fast
    }

    static func isAvailable(_ mode: Mode, engine: Engine) -> Bool {
        if mode == .mac { return engine.mac.route.host != nil }
        return engine.model(for: mode).map { engine.store.states[$0.id] == .ready } ?? false
    }
}

/// A deleted chat, kept for a few seconds so Undo can put it back.
struct DeletedChat: Identifiable {
    let id = UUID()
    let title: String
    let created: Date
    let updated: Date
    let mode: Mode
    let thinking: Thinking
    let pinned: Bool
    let messages: [StoredMessage]

    init(_ c: Conversation) {
        title = c.title
        created = c.created
        updated = c.lastActive
        mode = c.mode
        thinking = c.thinking
        pinned = c.pinned
        // A reply cut off by the delete is kept as stopped, not left looking unfinished.
        messages = c.messages.map { m in
            var m = m
            if !m.finished {
                m.finished = true
                if m.footnote == nil { m.footnote = "Stopped" }
            }
            return m
        }
    }

    func restore(into context: ModelContext) -> Conversation {
        let c = Conversation(mode: mode)
        c.title = title
        c.created = created
        c.lastActive = updated
        c.thinking = thinking
        c.pinned = pinned
        c.messages = messages
        context.insert(c)
        try? context.save()
        return c
    }
}

/// One chat in the sidebar: title and when, the last message, and the model.
struct ChatRow: View {
    let conversation: Conversation
    let answering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(conversation.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                if answering {
                    // Animates on its own: the row isn't redrawn while the reply streams.
                    Image(systemName: "ellipsis")
                        .symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Answering")
                } else {
                    Text(Self.when(conversation.lastActive)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let preview = Self.preview(conversation.messages) {
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            // Pinned chats have their own section, so the row doesn't mark them again.
            HStack(spacing: 4) {
                Label(conversation.modelTitle, systemImage: conversation.mode.symbol)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(conversation.pinned ? "Pinned" : "")
    }

    /// The last thing said, on one line. Messages are only written at a turn's start and end (and
    /// every few seconds while streaming), so this doesn't redraw the row per token.
    static func preview(_ messages: [StoredMessage]) -> String? {
        guard let text = messages.last(where: { !$0.content.isEmpty })?.content else { return nil }
        // Markdown marks and line breaks read as noise in one line.
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*-` \t")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
        return flat.isEmpty ? nil : String(flat.prefix(160))
    }

    /// Like Mail: the time today, "Yesterday", the weekday this week, else the date.
    static func when(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        if date >= week { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

/// "Deleted “…”  Undo", at the bottom of the window for a few seconds after a delete.
struct UndoToast: View {
    let deleted: DeletedChat
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Deleted “\(deleted.title)”").lineLimit(1)
            Button("Undo", action: undo).bold()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .shadow(radius: 6, y: 2)
        .padding()
        .padding(.bottom, 64)  // clear of the message box and the sidebar's bottom bar
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension PersistentIdentifier {
    /// For `@SceneStorage`, which only stores plain values.
    var stored: String? { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } }

    init?(stored: String?) {
        guard let stored, let id = try? JSONDecoder().decode(PersistentIdentifier.self, from: Data(stored.utf8)) else { return nil }
        self = id
    }
}
