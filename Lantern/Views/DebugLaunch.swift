#if DEBUG
import Foundation
import LlamaKit
import Network
import SwiftData
import UIKit

/// Launch arguments for a Debug build in the simulator
/// (`simctl launch <device> com.merimerimeri.Lantern -seedChats -ui sidebar`):
/// - `-model e2b|e4b|12b`: this device's model (`CatalogModel.device`); the simulator reports the
///   Mac's memory and runs llama.cpp on the CPU, so E2B is the one to use there.
/// - `-seedChats`: sample chats, once, the newest holding a comparison and a web search.
/// - `-ui welcome|model|modelpage|settings|mac|personalization|sidebar|search:<text>|chat|picker|compare|comparepicker`:
///   opens that a second after launch (`chat` and the last three open the seeded chat first).
/// - `-testflight`: show the build's expiry date in Settings.
/// - `-e2e [-mac]`: the app's end-to-end check (`scripts/e2e.sh`): a chat through `Engine`.
/// - `-pairCode <code>`: pairs by a typed code (`DebugPairing`).
/// - The Mac: `-role serve|client|none` sets what it does before launch goes on (`none`: the first
///   run's choice); `-ui role|pair` opens that choice, or Pair a Device; `-snapshot`, below.
enum DebugLaunch {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var ui: String? { value(after: "-ui") }

    static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }

    #if targetEnvironment(macCatalyst)
    /// The Mac: `-dark` or `-light` whatever the system is, and `-snapshot <path>`, which saves
    /// the window as `<path>.png`, and a sheet or popover over it as `-1.png`…, `-snapshotDelay`
    /// seconds after launch (4 unless given), then quits.
    static func snapshot() {
        let style: UIUserInterfaceStyle = arguments.contains("-dark") ? .dark : arguments.contains("-light") ? .light : .unspecified
        func window() -> UIWindow? {
            let all = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            all.forEach { $0.overrideUserInterfaceStyle = style }
            return all.first { !$0.isHidden && type(of: $0) == UIWindow.self }
        }
        _ = window()
        guard let path = value(after: "-snapshot") else { return }
        Task {
            try? await Task.sleep(for: .seconds(value(after: "-snapshotDelay").flatMap(Double.init) ?? 4))
            guard let main = window() else { exit(1) }
            try? await Task.sleep(for: .seconds(0.5))
            // A sheet or popover is a window of its own to AppKit, but its view is UIKit's, in
            // this window's hierarchy: drawn on its own, largest first like AppKit's windows.
            // Other windows (Settings) too.
            let windows = [main] + UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .compactMap { $0.windows.first { !$0.isHidden && type(of: $0) == UIWindow.self } }
                .filter { $0 !== main }
            var views: [UIView] = []
            for window in windows {
                views.append(window)
                var presented = window.rootViewController?.presentedViewController
                while let controller = presented {
                    views.append(controller.view)
                    presented = controller.presentedViewController
                }
            }
            views.sort { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
            let contents = views.map { view in
                UIGraphicsImageRenderer(bounds: view.bounds).pngData { _ in
                    view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
                }
            }
            MacUpdater.support?.snapshot(path, contents: contents)
            exit(0)
        }
    }
    #endif

    /// What `RootView` lets `-ui` do.
    struct Hooks {
        var settings: (SettingsPage?) -> Void
        var sheet: (RootView.Sheet) -> Void
        var sidebar: () -> Void
        var search: (String) -> Void
        var open: (_ title: String) -> Void
    }

    static func open(in hooks: Hooks) {
        #if targetEnvironment(macCatalyst)
        snapshot()
        #endif
        guard let ui else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            switch ui {
            case "welcome": hooks.sheet(.welcome)
            case "role": hooks.sheet(.role)
            case "pair": hooks.settings(.pairDevice)
            case "model": hooks.sheet(.model)
            case "settings": hooks.settings(nil)
            case "mac": hooks.settings(.mac)
            case "modelpage": hooks.settings(.model)
            case "personalization": hooks.settings(.personalization)
            case "sidebar": hooks.sidebar()
            case "chat", "picker", "compare", "comparepicker": hooks.open(sampleTitle)
            case let ui where ui.hasPrefix("search:"):
                hooks.sidebar()
                hooks.search(String(ui.dropFirst("search:".count)))
            default: break
            }
        }
    }

    static let sampleTitle = "Keeping bread fresh"

    static func seed(_ context: ModelContext) {
        #if targetEnvironment(macCatalyst)
        if let role = value(after: "-role") {
            if role == "none" {
                UserDefaults.standard.removeObject(forKey: MacRole.key)
            } else {
                UserDefaults.standard.set(role, forKey: MacRole.key)
            }
        }
        #endif
        let sample = sampleTitle
        guard arguments.contains("-seedChats"),
              (try? context.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == sample }))) == 0 else { return }
        let day: TimeInterval = 86_400
        let device = CatalogModel.device.name
        let samples: [(String, TimeInterval)] = [
            ("How a heat pump works", -3_600),
            ("Packing list for a weekend hike", -1.2 * day),
            ("Vegetable bed rotation", -2 * day),
            ("Friendlier email wording", -3 * day),
            ("Ideas for a rainy afternoon", -5 * day),
            ("What a Fourier transform is", -20 * day),
            ("Sourdough starter schedule", -40 * day),
        ]
        for (title, age) in samples {
            let c = Conversation(mode: .device)
            c.title = title
            c.lastActive = Date(timeIntervalSinceNow: age)
            c.created = c.lastActive
            c.messages = [
                StoredMessage(isUser: true, content: title + "?"),
                StoredMessage(isUser: false, content: "Here's a short answer about \(title.lowercased()).", footnote: device),
            ]
            context.insert(c)
        }

        // A chat with a web search, then a question answered twice: by this device's model (A)
        // and by the Mac's, thinking (B).
        let chat = Conversation(mode: .mac)
        chat.title = sampleTitle
        chat.macModel = "inkling-2-mini:latest"
        chat.webSearch = true
        chat.lastActive = .now
        var searched = StoredMessage(isUser: false)
        searched.searches = [
            WebSearch(query: "how long does sourdough stay fresh", results: [
                .init(title: "Storing sourdough bread", url: "https://www.example.com/storing-sourdough",
                      content: "Sourdough keeps for three to five days at room temperature…"),
                .init(title: "Why sourdough lasts longer", url: "https://www.example.org/sourdough-shelf-life",
                      content: "Its acidity slows staling and mould."),
            ]),
        ]
        searched.content = "A sourdough loaf stays good for **three to five days** at room temperature. Its acidity slows both staling and mould, so it outlasts most yeasted breads."
        searched.footnote = device
        searched.metrics = ReplyMetrics(modeRaw: Mode.device.rawValue, modelTitle: device)

        let compareID = UUID()
        var a = ReplyMetrics(modeRaw: Mode.device.rawValue, modelTitle: device)
        a.compareID = compareID
        a.thinking = false
        var b = ReplyMetrics(modeRaw: Mode.mac.rawValue, macModel: chat.macModel, modelTitle: "Inkling 2 Mini")
        b.compareID = compareID
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
        reply.footnote = "Inkling 2 Mini"
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
        older.footnote = device
        older.metrics = a
        reply.versions = [ReplyVersion(older)]
        chat.messages = [
            StoredMessage(isUser: true, content: "How long does a sourdough loaf stay fresh?"), searched,
            StoredMessage(isUser: true, content: "What's the best way to keep it fresh for a few days?"), reply,
        ]
        context.insert(chat)
        try? context.save()
    }
}

/// `-pairCode <code>`: pairs with the Mac showing that code, as Settings › Mac's Enter Code does
/// (Bonjour, then the proof), and prints `PAIR …` lines. Never prints the token.
@MainActor
enum DebugPairing {
    static func run(_ engine: Engine) async {
        guard let code = DebugLaunch.value(after: "-pairCode") else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let browser = BridgeBrowser()
        browser.start()
        defer { browser.stop() }
        for _ in 0..<(DebugLaunch.value(after: "-pairAt") == nil ? 40 : 4) where browser.advertised.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        print("PAIR found: \(browser.found.map { $0.name + ($0.fingerprint == nil ? " (no fingerprint)" : "") })\(browser.problem.map { " problem: " + $0 } ?? "")")
        // `-pairAt <host:port>@<fingerprint>`: that bridge instead of Bonjour's (a Debug build may
        // not have local network access granted yet).
        var bridges = browser.advertised
        if let at = DebugLaunch.value(after: "-pairAt")?.split(separator: "@"), at.count == 2,
           let colon = at[0].lastIndex(of: ":"), let port = NWEndpoint.Port(String(at[0][at[0].index(after: colon)...])) {
            bridges = [.init(name: "Bridge at \(at[0])", fingerprint: String(at[1]),
                             endpoint: .hostPort(host: .init(String(at[0][..<colon])), port: port))]
        }
        do {
            let paired = try await MacPairing.pair(code: code, device: Device.pairingName, bridges: bridges)
            engine.mac.configure(name: paired.name, lan: paired.lan, tailnet: paired.tailnet)
            await engine.mac.resolve()
            let join = switch paired.join {
            case .key: "a join key"
            case .notConfigured: "not configured"
            case .failed(let why): "failed: \(why)"
            }
            print("PAIR ok: \(paired.name) lan=\(paired.lan) tailnet=\(paired.tailnet.isEmpty ? "-" : paired.tailnet) tailscale=\(join) route=\(engine.mac.route.label) models=\(engine.mac.models)")
        } catch {
            print("PAIR failed: \(error.localizedDescription)")
        }
    }
}

/// `-e2e [-mac]`: the app's one end-to-end check, run by `scripts/e2e.sh`. Through `Engine`, in a
/// store of its own (no chats touched): send a question and get an answer, retry it, then reopen
/// the chat (the model unloaded, so it comes back from its saved state) and ask a follow-up.
/// Prints `E2E PASS|FAIL` lines and `E2E done`.
@MainActor
enum EndToEnd {
    private static var ran = false

    static func run(_ engine: Engine) async {
        guard DebugLaunch.arguments.contains("-e2e"), !ran else { return }
        ran = true
        setvbuf(stdout, nil, _IOLBF, 0)  // each line as it's printed, even into a pipe
        var failed = false
        func check(_ what: String, _ ok: Bool) {
            print("E2E \(ok ? "PASS" : "FAIL"): \(what)")
            if !ok { failed = true }
        }
        defer { print(failed ? "E2E done: FAILED" : "E2E done: ok") }
        guard let container = try? ModelContainer(
            for: Conversation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)) else { return check("a store opens", false) }
        let mac = DebugLaunch.arguments.contains("-mac")
        let chat = Conversation(mode: mac ? .mac : .device)
        chat.thinking = .off
        chat.webSearch = false
        container.mainContext.insert(chat)
        try? container.mainContext.save()
        func idle() async {
            repeat { try? await Task.sleep(for: .milliseconds(200)) } while engine.isBusy
            let m = chat.messages.last
            print("E2E reply: \((m?.content ?? "").prefix(80).debugDescription) | \(m?.footnote ?? "") | error: \(m?.error ?? "none")")
        }
        func answered() -> Bool {
            guard let m = chat.messages.last else { return false }
            return !m.isUser && m.finished && m.error == nil && !m.content.isEmpty
        }
        if !mac { check("\(engine.store.model.name) is downloaded", engine.store.isReady) }

        engine.send("In one sentence, what is a lantern?", in: chat)
        await idle()
        check("a question gets an answer", answered() && chat.messages.count == 2)
        check("the answer names its model", chat.messages.last?.metrics?.modelTitle.isEmpty == false)
        let first = chat.messages.last?.content

        engine.retry(in: chat)
        await idle()
        check("retry answers again", answered() && chat.messages.count == 2)
        check("retry keeps the first answer as a version", chat.messages.last?.versions?.first?.content == first)

        // Reopen: the model is freed (its state saved) and loaded again for the chat.
        try? await Task.sleep(for: .seconds(1))
        engine.unload()
        try? await Task.sleep(for: .seconds(1))
        if !mac {
            let saved = FileManager.default.subpaths(atPath: Engine.stateDirectory(for: chat).path) ?? []
            check("the chat's state is saved", !saved.isEmpty)
        }
        engine.prepare(chat)
        engine.send("Now say that in French.", in: chat)
        await idle()
        check("the reopened chat answers a follow-up", answered() && chat.messages.count == 4)
        engine.forgetState(for: chat)
    }
}
#endif
