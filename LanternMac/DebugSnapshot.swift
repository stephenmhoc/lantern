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
            // `-settings <tab>`: Settings open on that tab.
            if let t = args.firstIndex(of: "-settings"), args.indices.contains(t + 1) {
                UserDefaults.standard.set(args[t + 1], forKey: "settings.tab")
            }
            let delay = args.firstIndex(of: "-snapshotDelay").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 6
            try? await Task.sleep(for: .seconds(delay))
            for window in NSApp.windows where window.isVisible {
                // Vibrancy draws black into a cached image: hide it, so the window background shows.
                if let frame = window.contentView?.superview { hideEffects(in: frame) }
                // The whole frame, toolbar included.
                guard !window.title.isEmpty, let view = window.contentView?.superview ?? window.contentView,
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

    private static func hideEffects(in view: NSView) {
        if view is NSVisualEffectView { view.isHidden = true; return }
        view.subviews.forEach(hideEffects)
    }
}

/// `-ask <text> [-mode fast|smart|qwen|mac|apple]`: sends the question in the window's new chat once
/// the model can answer (for This Mac's, once the bridge is connected), for checking replies.
enum DebugAsk {
    static var question: String? { value(after: "-ask") }
    static var mode: Mode? { value(after: "-mode").flatMap(Mode.init(rawValue:)) }
    private static var asked = false

    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    private static func log(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

    static func run(in conversation: Conversation, engine: Engine) async {
        guard let question, !asked else { return }
        asked = true
        let mode = mode ?? .mac
        conversation.mode = mode
        if mode == .mac {
            for _ in 0..<60 where engine.mac.route.host == nil || engine.mac.models.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        log("ASK sending in \(conversation.modelTitle)")
        engine.send(question, in: conversation)
        while engine.running == nil { try? await Task.sleep(for: .milliseconds(100)) }
        while engine.running != nil { try? await Task.sleep(for: .milliseconds(250)) }
        let reply = conversation.messages.last
        log("ASK done: \(reply?.error ?? "ok") · \(reply?.footnote ?? "")")
        log("ASK answer: \(reply?.content.prefix(300) ?? "")")
        if ProcessInfo.processInfo.arguments.contains("-quit") {
            try? await Task.sleep(for: .seconds(1))  // the store's save
            // From the run loop, not this task: Quit waits on the main actor for the engine.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
    }
}
#endif
