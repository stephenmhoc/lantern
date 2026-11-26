import Foundation
import LlamaKit
import SwiftData
import SwiftUI

/// A group of chats in the sidebar, by when they were last used.
struct ChatSection: Identifiable {
    let title: String
    let chats: [Conversation]
    var id: String { title }

    /// `chats` must already be sorted newest first.
    static func group(_ chats: [Conversation], now: Date = .now, calendar: Calendar = .current) -> [ChatSection] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var todays: [Conversation] = [], yesterdays: [Conversation] = []
        var weeks: [Conversation] = [], older: [Conversation] = []
        for c in chats {
            if c.lastActive >= today { todays.append(c) }
            else if c.lastActive >= yesterday { yesterdays.append(c) }
            else if c.lastActive >= week { weeks.append(c) }
            else { older.append(c) }
        }
        return [
            ChatSection(title: "Today", chats: todays),
            ChatSection(title: "Yesterday", chats: yesterdays),
            ChatSection(title: "Previous 7 Days", chats: weeks),
            ChatSection(title: "Older", chats: older),
        ].filter { !$0.chats.isEmpty }
    }
}

/// What a new chat starts with: the model, thinking and web search last chosen in a chat.
enum ChatDefaults {
    nonisolated static let modeKey = "chat.lastMode", thinkingKey = "chat.lastThinking", searchKey = "chat.lastSearch"
    /// Settings' old "Search the Web" switch (see `Conversation.repairModes`).
    nonisolated static let oldSearchKey = "webSearch"

    /// The Mac only if it was used last and is still paired (always, on a Mac).
    static var mode: Mode {
        if Device.isMac { return .mac }
        return UserDefaults.standard.string(forKey: modeKey) == Mode.mac.rawValue && MacLink.isConfigured ? .mac : .device
    }
    nonisolated static var thinking: Thinking { UserDefaults.standard.bool(forKey: thinkingKey) ? .high : .off }
    nonisolated static var webSearch: Bool { UserDefaults.standard.bool(forKey: searchKey) }

    static func remember(_ c: Conversation) {
        let d = UserDefaults.standard
        d.set(c.mode.current.rawValue, forKey: modeKey)
        d.set(c.thinking != .off, forKey: thinkingKey)
        d.set(c.webSearch, forKey: searchKey)
    }
}

/// One chat in the side panel: its title (a few words from Apple Intelligence, or the first
/// question) on up to two lines, then when it was last used.
struct ChatRow: View {
    let conversation: Conversation
    let answering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conversation.title)
                .font(.body)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Group {
                if answering {
                    // Animates on its own: the row isn't redrawn while the reply streams.
                    HStack(spacing: 4) {
                        Text("Answering")
                        Image(systemName: "ellipsis")
                            .symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
                            .accessibilityHidden(true)
                    }
                } else {
                    Text(Self.when(conversation.lastActive))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)  // tertiary is under 3:1 in dark mode
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
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
