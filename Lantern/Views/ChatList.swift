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
    let macModel: String
    let thinking: Thinking
    let pinned: Bool
    let systemPrompt: String
    let historyStart: Int
    let messages: [StoredMessage]

    /// `comparing`: the id of the comparison running in `c` (`Engine.comparisonInProgress`). The
    /// unfinished B is left out and the chat is put back as it was before it: A shown, on A's model.
    init(_ c: Conversation, comparing: UUID? = nil) {
        title = c.title
        created = c.created
        updated = c.lastActive
        thinking = c.thinking
        pinned = c.pinned
        systemPrompt = c.systemPrompt
        historyStart = c.historyStart
        var messages = c.messages
        var mode = c.mode, macModel = c.macModel
        if let comparing, let last = messages.indices.last, !messages[last].isUser, !messages[last].finished,
           let a = Self.withoutB(messages[last], comparing: comparing) {
            messages[last] = a
            if let m = a.metrics, let aMode = Mode(rawValue: m.modeRaw) {
                mode = aMode
                if aMode == .mac, let model = m.macModel, !model.isEmpty { macModel = model }
            }
        }
        self.mode = mode
        self.macModel = macModel
        // A reply cut off by the delete is kept as stopped, not left looking unfinished.
        self.messages = messages.map { m in
            var m = m
            if !m.finished {
                m.finished = true
                if m.footnote == nil { m.footnote = "Stopped" }
            }
            return m
        }
    }

    /// The reply with the running B (the shown, newest answer) removed and A shown, no longer
    /// paired. Nil if A isn't among its versions.
    private static func withoutB(_ reply: StoredMessage, comparing: UUID) -> StoredMessage? {
        var (list, current) = reply.allVersions
        list.remove(at: current)
        guard let ai = list.lastIndex(where: { $0.metrics?.compareID == comparing }) ?? list.indices.last else { return nil }
        let a = list.remove(at: ai)
        var m = reply
        m.content = a.content
        m.thinking = a.thinking
        m.footnote = a.footnote
        m.error = a.error
        m.errorKind = nil
        m.cutOff = nil
        m.thoughtSeconds = a.thoughtSeconds
        m.metrics = a.metrics
        m.metrics?.compareID = nil
        m.metrics?.preferred = nil
        m.finished = true
        m.versions = list.isEmpty ? nil : list
        m.versionIndex = ai >= list.count ? nil : ai
        return m
    }

    func restore(into context: ModelContext) -> Conversation {
        let c = Conversation(mode: mode)
        c.title = title
        c.created = created
        c.lastActive = updated
        c.macModel = macModel
        c.thinking = thinking
        c.pinned = pinned
        if !systemPrompt.isEmpty { c.systemPrompt = systemPrompt }  // frozen per chat
        c.historyStart = historyStart
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
            // Not a Label: in a List it gets a fixed-width icon column, which left a gap.
            HStack(spacing: 4) {
                Image(systemName: conversation.mode.symbol).imageScale(.small)
                Text(conversation.modelTitle)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
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
