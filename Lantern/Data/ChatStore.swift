import CloudKit
import SwiftData

/// Where the chats are kept: one SwiftData store, mirrored to the user's private iCloud database,
/// so any iPhone, iPad or Mac signed in to it continues any chat with its own model (a chat stores
/// only "this device or the Mac"; each reply records the model that wrote it). The store is the
/// one each platform always used (iOS's default store; the Mac's `Chats.store`, the old Mac app's
/// too), so the chats already in it are uploaded the first time it syncs. Saved model states
/// stay in Caches, on each device.
///
/// Without an iCloud account the same store works on its own and syncs once one is signed in;
/// Settings says so, quietly. A build without the iCloud entitlement keeps it local.
enum ChatStore {
    static let cloudContainer = "iCloud.com.merimerimeri.Lantern"

    /// Whether the store is mirrored to iCloud (it opened with CloudKit).
    private(set) static var syncs = false

    static let container: ModelContainer = {
        let schema = Schema([Conversation.self])
        func configuration(_ cloud: ModelConfiguration.CloudKitDatabase) -> ModelConfiguration {
            #if targetEnvironment(macCatalyst)
            // The Mac app isn't sandboxed: its own folder, not the default store every
            // unsandboxed app would share.
            ModelConfiguration(schema: schema, url: Folders.chats, cloudKitDatabase: cloud)
            #else
            ModelConfiguration(schema: schema, cloudKitDatabase: cloud)
            #endif
        }
        do {
            let container = try ModelContainer(for: schema, configurations: configuration(.private(cloudContainer)))
            syncs = true
            return container
        } catch {
            print("Lantern: the chats don't sync with iCloud: \(error)")
        }
        do {
            return try ModelContainer(for: schema, configurations: configuration(.none))
        } catch { fatalError("Couldn't open the chats: \(error)") }
    }()

    /// Whether this device is signed in to iCloud (nil while it can't tell, or the store doesn't
    /// sync). Without an account the chats stay on this device.
    static func signedIn() async -> Bool? {
        guard syncs else { return nil }
        switch try? await CKContainer(identifier: cloudContainer).accountStatus() {
        case .available: return true
        case .noAccount, .restricted: return false
        default: return nil
        }
    }
}
