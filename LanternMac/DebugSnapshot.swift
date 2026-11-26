#if DEBUG
import AppKit

/// `-snapshot <folder>`: a few seconds after launch, draws each open window into
/// `<folder>/<window title>.png` (no Screen Recording permission needed), for checking the UI.
enum DebugSnapshot {
    static func scheduleIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-snapshot"), args.indices.contains(i + 1) else { return }
        let folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        // Light, unless `-dark`: the drawing has no window background behind it.
        let dark = args.contains("-dark")
        Task { @MainActor in
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .seconds(6))
            for window in NSApp.windows where window.isVisible {
                guard !window.title.isEmpty, let view = window.contentView,
                      let content = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: content)
                // The view draws without the window's background: put it on that, in the window's appearance.
                let size = content.size
                let image = NSImage(size: size)
                image.lockFocus()
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSRect(origin: .zero, size: size).fill()
                }
                content.draw(in: NSRect(origin: .zero, size: size))
                image.unlockFocus()
                guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: folder.appending(path: "\(window.title).png"))
            }
            print("SNAPSHOT done")
        }
    }
}
#endif
