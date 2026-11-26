import Foundation
import UIKit

/// What this device is, where Lantern differs by it.
nonisolated enum Device {
    /// A Mac has no model of its own: it serves its model to the others, or uses another Mac's
    /// (`MacRole`). Every chat on it is answered through `MacLink`.
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// "iPhone", "iPad" or "Mac", for copy that says "this …".
    @MainActor static var name: String { isMac ? "Mac" : UIDevice.current.localizedModel }

    /// What it's called on the Mac it pairs with: the device's name, or a Mac's kind from its
    /// host name ("MacBook Pro").
    @MainActor static var pairingName: String {
        isMac ? MacLink.derivedName(fromHost: ProcessInfo.processInfo.hostName) ?? "Mac" : UIDevice.current.name
    }
}

/// Where Lantern keeps its files. On iOS the app's own Documents (the model's files) and Caches.
/// The Mac app isn't sandboxed, so there it's a folder of Lantern's own in Application Support
/// (the one the Mac app has always used: `Chats.store`, the bridge's `Bridge/`) and in Caches.
nonisolated enum Folders {
    #if targetEnvironment(macCatalyst)
    /// A Debug build's bundle ID ends in `.dev` and it keeps to "Lantern Dev", so it never
    /// touches the installed app's chats or bridge.
    static let isDevBuild = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true

    /// ~/Library/Application Support/Lantern
    static let support: URL = {
        let url = URL.applicationSupportDirectory.appending(path: isDevBuild ? "Lantern Dev" : "Lantern", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The chats, where the Mac app before this one kept them too.
    static var chats: URL { support.appending(path: "Chats.store") }
    #endif

    /// The model's files. Never used on the Mac, which has none.
    static var models: URL {
        #if targetEnvironment(macCatalyst)
        support.appending(path: "Models", directoryHint: .isDirectory)
        #else
        URL.documentsDirectory
        #endif
    }

    /// Saved model states and other things that can be made again.
    static var caches: URL {
        #if targetEnvironment(macCatalyst)
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "com.merimerimeri.Lantern", directoryHint: .isDirectory)
        #else
        URL.cachesDirectory
        #endif
    }
}
