import LlamaKit
#if DEBUG
import Foundation
import CoreSpotlight
import SwiftData
import UIKit

/// Launch arguments for checking the shell in the simulator without tapping
/// (`simctl launch <device> com.merimerimeri.Lantern -seedChats -ui inspector`):
/// - `-seedChats`: adds sample chats across the sidebar's sections, once.
/// - `-ui readiness|settings|personalization|inspector|search:<text>`: opens that on launch.
/// - `-ui delete|newchat|sidebar|swipe|swipepin|next|window`: runs that action a second after launch (window:
///   opens the oldest chat in a new window).
/// - `-testflight` (in ReadinessView): pretend to be a TestFlight install.
/// - `-openURL <lantern://…>`: the app opens the link itself two seconds after launch, through the
///   system like any other app would, without `simctl openurl`'s "Open in Lantern?" prompt.
/// - `-ui inspector` opens the chat's info panel.
/// - `-ui compare` (or `compare:b`): adds a chat whose last reply is a comparison (Gemma 4 E2B on
///   this device against Inkling 2 Mini on the Mac, with sample metrics), opens it and shows the
///   compare sheet on A (or B). Add `:metrics` (`compare:b:metrics`) to scroll to the table.
///   `compare:chat` opens the chat only, for the answer's ‹ 1/2 › pager.
/// - `-ui composer:focus|composer:text`: the message box expanded, focused or holding a draft.
/// - `-ui modelmenu|modelmenu:collapsed`: the model picker open, from the expanded or collapsed box.
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
        if ui?.hasPrefix("compare") == true { seedComparison(context) }
        if ui == "search" { seedSearch(context) }
        guard arguments.contains("-seedChats"),
              (try? context.fetchCount(FetchDescriptor<Conversation>())) == 0 else { return }
        let day: TimeInterval = 86_400
        let samples: [(String, TimeInterval, Mode, Bool)] = [
            ("Sourdough starter schedule", -40 * day, .smart, true),
            ("Explain how a heat pump works", -600, .fast, false),
            ("Packing list for a weekend hike", -1.2 * day, .fast, false),
            ("Rewrite this email more politely", -3 * day, .mac, false),
            ("What is a Fourier transform?", -20 * day, .smart, false),
            ("Plan a vegetable bed rotation", -2 * day, .qwen, false),
            ("Ideas for a rainy afternoon", -5 * day, .apple, false),
        ]
        for (title, age, mode, pinned) in samples {
            let model = mode == .mac ? "Inkling 2 Mini on your Mac" : mode.title
            let c = Conversation(mode: mode)
            c.title = title
            c.lastActive = Date(timeIntervalSinceNow: age)
            c.created = c.lastActive
            c.pinned = pinned
            c.messages = [
                StoredMessage(isUser: true, content: title + "?"),
                StoredMessage(isUser: false, content: "Here's a short answer about \(title.lowercased()).",
                              footnote: "\(model) · 14.2 tok/s · 0.8 s to first token"),
            ]
            context.insert(c)
        }
        try? context.save()
    }
}

extension DebugLaunch {
    /// The `-ui compare` chat's `stateID`, for opening it by its link.
    static let comparisonChatID = "debug-compare"

    /// A chat whose last reply holds a comparison: A from Gemma 4 E2B on this device, B from
    /// Inkling 2 Mini on the Mac. Added once; it becomes the latest chat.
    static func seedComparison(_ context: ModelContext) {
        let id = comparisonChatID
        let existing = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.stateID == id }))) ?? []
        if let chat = existing.first {
            chat.lastActive = .now
            try? context.save()
            return
        }
        let chat = Conversation(mode: .mac)
        chat.stateID = id
        chat.title = "Keeping bread fresh"
        chat.macModel = "inkling-2-mini:latest"
        chat.lastActive = .now
        let compareID = UUID()
        let question = "What's the best way to keep a loaf of sourdough fresh for a few days?"

        var a = ReplyMetrics(modeRaw: Mode.fast.rawValue, modelTitle: Mode.fast.title)
        a.compareID = compareID
        a.loadSeconds = 3.8
        a.firstTokenSeconds = 0.6
        a.firstAnswerSeconds = 0.6
        a.promptTokens = 412
        a.reusedTokens = 380
        a.promptSeconds = 0.4
        a.restored = false
        a.generatedTokens = 236
        a.generateSeconds = 11.2
        a.tokensPerSecond = 21.1
        a.totalSeconds = 15.6
        a.thinking = false

        var b = ReplyMetrics(modeRaw: Mode.mac.rawValue, macModel: "inkling-2-mini:latest", modelTitle: "Inkling 2 Mini")
        b.compareID = compareID
        b.loadSeconds = 0
        b.firstTokenSeconds = 0.9
        b.firstAnswerSeconds = 6.4
        b.promptTokens = 431
        b.promptSeconds = 0.3
        b.generatedTokens = 512
        b.generateSeconds = 36.5
        b.tokensPerSecond = 14.0
        b.totalSeconds = 37.8
        b.findSeconds = 0.2
        b.connectSeconds = 0.05
        b.route = "Home network"
        b.thinking = true

        var reply = StoredMessage(isUser: false)
        reply.content = """
        Keep it **cut side down** on a wooden board for the first day, then in a bread bag or box.

        1. **Day 1:** leave it uncovered, crust out, cut side on the board.
        2. **Days 2–3:** a paper or cloth bag; plastic softens the crust.
        3. **Longer:** slice it and freeze; toast slices straight from the freezer.

        Avoid the fridge: it goes stale faster there than on the counter.
        """
        reply.thinking = "The user wants storage advice. Cover crust, cut side, fridge vs freezer."
        reply.thoughtSeconds = 5
        reply.footnote = "Inkling 2 Mini · 14.0 tok/s · 0.9 s to first token"
        reply.metrics = b
        var older = StoredMessage(isUser: false)
        older.content = """
        Sourdough keeps well for **2–3 days** at room temperature:

        - Store it **cut side down** on a board so the crumb doesn't dry out.
        - After the first day, use a **paper bag** or a bread box.
        - For longer, **slice and freeze** it:

        ```text
        freezer bag → up to 3 months
        toast from frozen
        ```

        Don't refrigerate it; that makes it stale faster.
        """
        older.footnote = "Gemma 4 E2B · 21.1 tok/s · 0.6 s to first token"
        older.metrics = a
        reply.versions = [ReplyVersion(older)]
        chat.messages = [StoredMessage(isUser: true, content: question), reply]
        context.insert(chat)
        try? context.save()
    }

    static let searchChatID = "debug-search"

    /// `-ui search`: a chat on the Mac whose answer ran two web searches, one of which failed.
    static func seedSearch(_ context: ModelContext) {
        let id = searchChatID
        if let chat = ((try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.stateID == id }))) ?? []).first {
            context.delete(chat)
        }
        let chat = Conversation(mode: .mac)
        chat.stateID = id
        chat.title = "Ferry to Bainbridge"
        chat.macModel = "inkling-2-mini:latest"
        chat.lastActive = .now
        var reply = StoredMessage(isUser: false)
        reply.searches = [
            WebSearch(query: "Seattle Bainbridge ferry schedule today", results: [
                .init(title: "Seattle / Bainbridge Island – Sailing Schedule", url: "https://wsdot.com/ferries/schedule/seattle-bainbridge",
                      content: "Departs Seattle 5:30 PM, 6:20 PM, 7:05 PM…"),
                .init(title: "Bainbridge ferry delays and alerts", url: "https://www.example.com/bainbridge-alerts",
                      content: "One-boat service this evening."),
            ]),
            WebSearch(query: "Bainbridge ferry vehicle wait time", error: "The search took too long."),
        ]
        reply.content = "The next sailings from Seattle are at **5:30**, **6:20** and **7:05 PM**. There's one-boat service this evening, so expect waits for cars."
        reply.footnote = "Inkling 2 Mini on your Mac · 72.0 tok/s · 0.3 s to first token"
        chat.messages = [StoredMessage(isUser: true, content: "When's the next ferry to Bainbridge?"), reply]
        context.insert(chat)
        try? context.save()
    }

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
        if ui?.hasPrefix("compare") == true {
            _ = await UIApplication.shared.open(LanternLink.chat(id: comparisonChatID).url)
        }
        if ui == "search" { _ = await UIApplication.shared.open(LanternLink.chat(id: searchChatID).url) }
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
