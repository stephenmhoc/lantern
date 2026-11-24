import CoreSpotlight
import SwiftData
import UIKit

/// Keeps Spotlight in step with the chats: title plus the first few lines. Runs after every save
/// of the store (a turn start or end, a rename, a delete), batched, and diffs against what it
/// last indexed (remembered in UserDefaults), so only changed chats are re-indexed and deleted
/// ones removed. Tapping a result opens the chat through `onContinueUserActivity` in `RootView`.
enum SpotlightIndex {
    static let domain = "chats"
    private static let indexedKey = "spotlight.indexed"
    private static var pending: Task<Void, Never>?

    static func start(_ container: ModelContainer) {
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { schedule(container) }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { schedule(container, after: .zero) }
        }
        schedule(container, after: .seconds(3))  // at launch, out of the way of the first window
    }

    private static func schedule(_ container: ModelContainer, after delay: Duration = .seconds(1)) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await reconcile(container.mainContext)
        }
    }

    static func reconcile(_ context: ModelContext) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let chats = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        let before = UserDefaults.standard.dictionary(forKey: indexedKey) as? [String: String] ?? [:]
        var now: [String: String] = [:]
        var changed: [CSSearchableItem] = []
        for c in chats where !c.messages.isEmpty {  // an empty "New chat" isn't worth finding
            let id = c.externalID
            let signature = "\(c.lastActive.timeIntervalSince1970)|\(c.title)"
            now[id] = signature
            guard before[id] != signature else { continue }
            let entity = ChatEntity(c)
            let attributes = entity.attributeSet
            attributes.associateAppEntity(entity)
            let item = CSSearchableItem(uniqueIdentifier: id, domainIdentifier: domain, attributeSet: attributes)
            item.expirationDate = .distantFuture
            changed.append(item)
        }
        if context.hasChanges { try? context.save() }  // ids given to old chats
        let removed = Array(Set(before.keys).subtracting(now.keys))
        let index = CSSearchableIndex.default()
        do {
            if !changed.isEmpty { try await index.indexSearchableItems(changed) }
            if !removed.isEmpty { try await index.deleteSearchableItems(withIdentifiers: removed) }
            UserDefaults.standard.set(now, forKey: indexedKey)
            if !changed.isEmpty || !removed.isEmpty { LanternShortcuts.updateAppShortcutParameters() }
            #if DEBUG
            print("SPOTLIGHT indexed \(changed.count), removed \(removed.count), \(now.count) in all")
            #endif
        } catch {
            print("Spotlight: \(error.localizedDescription)")
        }
    }
}
