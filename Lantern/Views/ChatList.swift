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
            else if c.updated >= today { todays.append(c) }
            else if c.updated >= yesterday { yesterdays.append(c) }
            else if c.updated >= week { weeks.append(c) }
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
/// does (the Mac if it answers, then Fast, then Smart).
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
        updated = c.updated
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
        c.updated = updated
        c.thinking = thinking
        c.pinned = pinned
        c.messages = messages
        context.insert(c)
        try? context.save()
        return c
    }
}

/// One chat in the sidebar.
struct ChatRow: View {
    let conversation: Conversation
    let answering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title).lineLimit(1)
            HStack(spacing: 4) {
                Label(conversation.mode.title, systemImage: conversation.mode.symbol)
                if answering { Text("· Answering") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(conversation.pinned ? "Pinned" : "")
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
