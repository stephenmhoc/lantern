#if DEBUG
import Foundation
import SwiftData

/// Launch arguments for checking the shell in the simulator without tapping
/// (`simctl launch <device> com.merimerimeri.Lantern -seedChats -ui inspector`):
/// - `-seedChats`: adds sample chats across the sidebar's sections, once.
/// - `-ui readiness|settings|inspector|search:<text>`: opens that on launch.
/// - `-ui delete|newchat|sidebar|next|window`: runs that action a second after launch (window:
///   opens the oldest chat in a new window).
/// - `-testflight` (in ReadinessView): pretend to be a TestFlight install.
enum DebugLaunch {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var ui: String? {
        guard let i = arguments.firstIndex(of: "-ui"), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }

    /// `-importModel <path>`: runs the Readiness import on a file, printing the result.
    static var importPath: String? {
        guard let i = arguments.firstIndex(of: "-importModel"), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }

    static func seed(_ context: ModelContext) {
        guard arguments.contains("-seedChats"),
              (try? context.fetchCount(FetchDescriptor<Conversation>())) == 0 else { return }
        let day: TimeInterval = 86_400
        let samples: [(String, TimeInterval, Mode, Bool)] = [
            ("Sourdough starter schedule", -40 * day, .smart, true),
            ("Explain how a heat pump works", -600, .fast, false),
            ("Packing list for a weekend hike", -1.2 * day, .fast, false),
            ("Rewrite this email more politely", -3 * day, .mac, false),
            ("What is a Fourier transform?", -20 * day, .smart, false),
        ]
        for (title, age, mode, pinned) in samples {
            let c = Conversation(mode: mode)
            c.title = title
            c.updated = Date(timeIntervalSinceNow: age)
            c.created = c.updated
            c.pinned = pinned
            c.messages = [
                StoredMessage(isUser: true, content: title + "?"),
                StoredMessage(isUser: false, content: "Here's a short answer about \(title.lowercased()).",
                              footnote: "Gemma 4 E2B · 14.2 tok/s · 0.8 s to first token"),
            ]
            context.insert(c)
        }
        try? context.save()
    }
}
#endif
