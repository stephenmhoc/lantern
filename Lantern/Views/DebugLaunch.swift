#if DEBUG
import Foundation
import CoreSpotlight
import SwiftData
import UIKit

/// Launch arguments for checking the shell in the simulator without tapping
/// (`simctl launch <device> com.merimerimeri.Lantern -seedChats -ui inspector`):
/// - `-seedChats`: adds sample chats across the sidebar's sections, once.
/// - `-ui readiness|settings|inspector|search:<text>`: opens that on launch.
/// - `-ui delete|newchat|sidebar|next|window`: runs that action a second after launch (window:
///   opens the oldest chat in a new window).
/// - `-testflight` (in ReadinessView): pretend to be a TestFlight install.
/// - `-openURL <lantern://…>`: the app opens the link itself two seconds after launch, through the
///   system like any other app would, without `simctl openurl`'s "Open in Lantern?" prompt.
/// - `-intent ask:<text>|new:<mode>|open:<chat title>`: runs that App Intent's `perform()`.
/// - `-spotlightQuery <text>`: searches Lantern's own Spotlight items after indexing and prints them.
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

extension DebugLaunch {
    private static var ranSystem = false

    static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }

    /// `-openURL` and `-intent`, once per launch.
    static func system() async {
        guard !ranSystem else { return }
        ranSystem = true
        try? await Task.sleep(for: .seconds(2))
        if let string = value(after: "-openURL"), let url = URL(string: string) {
            let opened = await UIApplication.shared.open(url)
            print("OPENURL \(string): \(opened)")
        }
        if let text = value(after: "-spotlightQuery") {
            try? await Task.sleep(for: .seconds(4))  // after SpotlightIndex's launch pass
            let context = CSSearchQueryContext()
            context.fetchAttributes = ["title"]
            let query = CSSearchQuery(queryString: "title == \"*\(text)*\"cd", queryContext: context)
            do {
                for try await result in query.results {
                    print("SPOTLIGHT found \(result.item.uniqueIdentifier): \(result.item.attributeSet.title ?? "")")
                }
                print("SPOTLIGHT query done")
            } catch {
                print("SPOTLIGHT query failed: \(error)")
            }
        }
        guard let spec = value(after: "-intent") else { return }
        let (kind, argument) = spec.split(separator: ":", maxSplits: 1).map(String.init).splitPair
        do {
            switch kind {
            case "ask":
                let intent = AskLanternIntent()
                intent.text = argument
                intent.mode = .usual
                _ = try await intent.perform()
            case "new":
                _ = try await NewChatIntent(mode: ChatModeChoice(rawValue: argument) ?? .usual).perform()
            case "open":
                guard let chat = try await ChatQuery().entities(matching: argument).first else {
                    print("INTENT no chat matches \(argument)"); return
                }
                let intent = OpenChatIntent()
                intent.target = chat
                _ = try await intent.perform()
            default:
                print("INTENT unknown \(kind)"); return
            }
            print("INTENT \(spec): performed")
        } catch {
            print("INTENT \(spec): \(error)")
        }
    }
}

private extension Array where Element == String {
    var splitPair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}
#endif
