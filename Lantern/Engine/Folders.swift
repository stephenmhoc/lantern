import Foundation

/// Where Lantern keeps its files. On iOS the app's own Documents (model files, visible in the
/// Files app and Finder) and Caches. On the Mac, which isn't sandboxed, folders of Lantern's own
/// inside the user's Library, so nothing lands loose in ~/Documents or ~/Library/Caches.
nonisolated enum Folders {
    /// Downloaded and imported model files.
    static var models: URL {
        #if os(macOS)
        let url = URL.applicationSupportDirectory.appending(path: "Lantern/Models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
        #else
        URL.documentsDirectory
        #endif
    }

    /// Saved model states and other things that can be made again.
    static var caches: URL {
        #if os(macOS)
        let url = URL.cachesDirectory.appending(path: "com.merimerimeri.Lantern", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
        #else
        URL.cachesDirectory
        #endif
    }
}
