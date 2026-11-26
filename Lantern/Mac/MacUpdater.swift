#if targetEnvironment(macCatalyst)
import Foundation

/// The Mac app's updates: Sparkle, which is AppKit, so it lives in MacSupport.bundle (in the
/// app's PlugIns) behind `MacSupportAPI`. It checks by itself once started; "Check for Updates…"
/// in the app menu asks now. The feed is `SUFeedURL` in Info.plist (`LANTERN_FEED_URL`).
enum MacUpdater {
    static let support: MacSupportAPI? = {
        guard let url = Bundle.main.builtInPlugInsURL?.appending(path: "MacSupport.bundle"),
              let bundle = Bundle(url: url), (try? bundle.loadAndReturnError()) != nil,
              let type = bundle.principalClass as? NSObject.Type else { return nil }
        return type.init() as? MacSupportAPI
    }()
    private static var started = false

    /// At launch. A Debug build doesn't update itself unless asked to (`-updater`).
    static func start() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-updater") else { return }
        #endif
        support?.startUpdater()
        started = support != nil
    }

    static var canCheck: Bool { started && support?.canCheckForUpdates == true }
    static func check() { support?.checkForUpdates() }
}
#endif
