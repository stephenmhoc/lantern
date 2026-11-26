import AppKit
import Sparkle

/// The bundle's principal class: Lantern loads MacSupport.bundle from its PlugIns at launch and
/// makes one of these (`MacUpdater`). Sparkle reads the feed (`SUFeedURL`) and the key updates are
/// signed with (`SUPublicEDKey`) from the app's own Info.plist.
@objc(LanternMacSupport) final class MacSupport: NSObject, MacSupportAPI {
    private var updater: SPUStandardUpdaterController?

    func startUpdater() {
        guard updater == nil else { return }
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var canCheckForUpdates: Bool { updater?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() { updater?.checkForUpdates(nil) }

    #if DEBUG
    /// Each window: its content as UIKit drew it (`contents`, largest first), with the window's
    /// own frame (title bar, toolbar) blended over it: the frame draws itself on an opaque
    /// background, so only what's darker than the content is kept (lighter, in dark mode).
    /// Nothing here needs the screen: the window server's own picture of a window is blank
    /// while the Mac is locked.
    func snapshot(_ path: String, contents: [Data]) {
        let windows = NSApp.windows.filter(\.isVisible)
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        for (i, window) in windows.enumerated() {
            guard let frame = window.contentView?.superview, let chrome = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
            frame.cacheDisplay(in: frame.bounds, to: chrome)
            let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let image = NSImage(size: frame.bounds.size)
            image.lockFocus()
            if contents.indices.contains(i), let content = NSImage(data: contents[i]) {
                content.draw(in: NSRect(origin: .zero, size: content.size))
                chrome.draw(in: frame.bounds, from: .zero, operation: dark ? .lighten : .multiply, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                chrome.draw(in: frame.bounds)
            }
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: i == 0 ? "\(path).png" : "\(path)-\(i).png"))
        }
    }
    #endif
}
