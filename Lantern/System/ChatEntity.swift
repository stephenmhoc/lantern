import AppIntents
import CoreSpotlight
import SwiftData

extension Conversation {
    /// The id deep links, Spotlight and App Intents use for this chat: its `stateID`, which is set
    /// once and never changes. Chats from before `stateID` existed get one here.
    var externalID: String {
        if stateID.isEmpty { stateID = UUID().uuidString }
        return stateID
    }

    /// The start of the chat, for Spotlight and the Shortcuts picker: the first question and answer.
    var snippet: String {
        let text = messages.prefix(2).map(\.content).joined(separator: "\n")
        let lines = text.split(whereSeparator: \.isNewline).prefix(3).joined(separator: "\n")
        return String(lines.prefix(300))
    }
}

/// A chat, for "Open Chat", Siri and Spotlight. Built from a `Conversation`; the app's own
/// `CSSearchableItem`s carry it too (`SpotlightIndex`).
nonisolated struct ChatEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chat")
    static let defaultQuery = ChatQuery()

    let id: String
    let title: String
    let snippet: String
    let modeSymbol: String
    let updated: Date

    @MainActor
    init(_ c: Conversation) {
        id = c.externalID
        title = c.title
        snippet = c.snippet
        modeSymbol = c.mode.symbol
        updated = c.updated
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: snippet.isEmpty ? nil : "\(snippet.prefix(80))",
            image: .init(systemName: modeSymbol)
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = title
        set.displayName = title
        set.contentDescription = snippet
        set.contentModificationDate = updated
        set.keywords = ["Lantern", "chat"]
        return set
    }
}

/// Looks chats up in the app's store. Runs in the app's process (the intents that use it open the app).
nonisolated struct ChatQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ChatEntity] {
        let ids = Set(identifiers)
        return fetch().filter { ids.contains($0.stateID) }.map(ChatEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ChatEntity] {
        ChatSection.filter(fetch(), query: string).prefix(30).map(ChatEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ChatEntity] {
        fetch(limit: 10).map(ChatEntity.init)
    }

    @MainActor
    private func fetch(limit: Int? = nil) -> [Conversation] {
        var descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updated, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? LanternApp.container.mainContext.fetch(descriptor)) ?? []
    }
}
