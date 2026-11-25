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

    /// The chats matching `query` anywhere the sidebar's search looks (`ChatSearch`): titles,
    /// questions and answers with their other versions, attached files and thinking. For callers
    /// that only need the chats (`ChatQuery`); the sidebar shows `ChatSearch.run`'s results.
    static func filter(_ chats: [Conversation], query: String) -> [Conversation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return chats }
        return chats.filter { ChatSearch.matches($0, query: q) }
    }
}

/// The mode a new chat starts in: the last one used if it works right now, else the quickest that
/// does (the Mac if it answers, then Gemma 4 E2B, then E4B, then Qwen 3.5 4B, then Apple
/// Intelligence: last, since its small context fills after a few turns; first only for someone who
/// has downloaded nothing, where it means a new chat works at once).
enum DefaultMode {
    static let key = "chat.lastMode"

    static func pick(last: String, engine: Engine) -> Mode {
        if let last = Mode(rawValue: last), isAvailable(last, engine: engine) { return last }
        return [Mode.mac, .fast, .smart, .qwen, .apple].first { isAvailable($0, engine: engine) } ?? .fast
    }

    static func isAvailable(_ mode: Mode, engine: Engine) -> Bool {
        if mode == .mac { return engine.mac.route.host != nil }
        if mode == .apple { return engine.apple.status.isAvailable }
        return engine.model(for: mode).map { engine.store.states[$0.id] == .ready } ?? false
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
            // Not a Label: in a List it gets a fixed-width icon column, which left a gap.
            HStack(spacing: 4) {
                Image(systemName: conversation.mode.symbol).imageScale(.small)
                Text(conversation.modelTitle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)  // tertiary is under 3:1 in dark mode
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

extension PersistentIdentifier {
    /// For `@SceneStorage`, which only stores plain values.
    var stored: String? { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } }

    init?(stored: String?) {
        guard let stored, let id = try? JSONDecoder().decode(PersistentIdentifier.self, from: Data(stored.utf8)) else { return nil }
        self = id
    }
}
