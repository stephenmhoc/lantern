import Foundation

/// The one door between the Mac app (Mac Catalyst, so UIKit) and MacSupport.bundle, which holds
/// what only AppKit can do: Sparkle. Compiled into both; they meet by its Objective-C name.
@objc(LanternMacSupportAPI) protocol MacSupportAPI: NSObjectProtocol {
    /// Starts Sparkle, which then checks for updates on its own schedule.
    func startUpdater()
    /// False while a check is already under way.
    var canCheckForUpdates: Bool { get }
    /// "Check for Updates…": Sparkle's own window says what it found.
    func checkForUpdates()

    #if DEBUG
    /// Each window as a PNG, for checking the UI: `<path>.png`, and `<path>-1.png`… for any
    /// others (popovers), largest first. `contents` are the windows as UIKit drew them, in that
    /// order; this adds the title bar and toolbar, which are AppKit's.
    func snapshot(_ path: String, contents: [Data])
    #endif
}
