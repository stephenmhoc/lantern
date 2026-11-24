import SwiftData
import SwiftUI

@main
struct LanternApp: App {
    /// The one window group. Opened with a chat's identifier for "Open in New Window", with none
    /// for an ordinary window. Every window shares `engine`, so one generation runs at a time.
    static let mainWindow = "main"

    /// The one store, shared by the windows and by App Intents and Spotlight (`ChatQuery`, `SpotlightIndex`).
    static let container: ModelContainer = {
        do { return try ModelContainer(for: Conversation.self) } catch { fatalError("Couldn't open the chats: \(error)") }
    }()

    init() {
        Conversation.repairActivity(in: Self.container.mainContext)
        SpotlightIndex.start(Self.container)
    }

    @State private var engine = Engine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(id: Self.mainWindow, for: PersistentIdentifier.self) { $opened in
            RootView(opened: opened)
                .environment(engine)
                .environment(engine.store)
                .environment(engine.mac)
                .task {
                    await Readiness.checkEnvironment()
                    // Reschedules the expiry reminders if they're already allowed; never asks.
                    await ExpiryReminders.reschedule()
                }
                #if DEBUG
                // `-selftest`: runs Readiness's Test on each downloaded model at launch and prints
                // the result, to check a build without tapping (simctl launch --console).
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("-selftest"), !Self.selfTested else { return }
                    Self.selfTested = true
                    for model in CatalogModel.all where engine.store.states[model.id] == .ready {
                        do {
                            let s = try await engine.test(model)
                            print("SELFTEST \(model.name): ok, \(s.generatedTokens) tokens at \(s.tokensPerSecond) tok/s")
                        } catch {
                            print("SELFTEST \(model.name): \(error.localizedDescription)")
                        }
                    }
                    print("SELFTEST done")
                }
                .modifier(EngineTest(engine: engine))
                .task { await CompareTest.run(engine) }
                .task { await DebugLaunch.system() }  // -openURL, -intent
                #endif
        }
        .modelContainer(Self.container)
        .commands { LanternCommands(engine: engine) }
        .onChange(of: scenePhase) { _, phase in
            // The app's phase: background only once every window is.
            if phase == .background { engine.didEnterBackground() }
            if phase == .active { engine.didBecomeActive() }
        }
        // Lets model downloads finish while Lantern is in the background.
        .backgroundTask(.urlSession(ModelStore.sessionID)) {
            await withCheckedContinuation { continuation in
                Task { @MainActor in ModelStore.shared.onBackgroundEventsDone { continuation.resume() } }
            }
        }
    }

    #if DEBUG
    private static var selfTested = false
    #endif
}

#if DEBUG
/// `-enginetest`: drives a short Fast chat through `Engine` at launch (send, follow-up, retry,
/// stop) and prints what happened, to check the engine without tapping (simctl launch --console).
private struct EngineTest: ViewModifier {
    let engine: Engine
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.task {
            guard ProcessInfo.processInfo.arguments.contains("-enginetest") else { return }
            // Chats from an older build must still open: their stored messages predate newer fields.
            for old in (try? context.fetch(FetchDescriptor<Conversation>())) ?? [] {
                print("ENGINETEST existing chat: \(old.messages.count) messages, \(old.history(before: old.messages.count).count) in history")
            }
            let mode: Mode = ProcessInfo.processInfo.arguments.contains("-smart") ? .smart : .fast
            let chat = Conversation(mode: mode)
            context.insert(chat)
            @MainActor func idle() async {
                repeat { try? await Task.sleep(for: .milliseconds(200)) } while engine.isBusy
                let m = chat.messages.last
                let usage = engine.contextUsage(for: chat)
                print("ENGINETEST reply: \(m?.content.prefix(60) ?? "") | \(m?.footnote ?? "") | error: \(m?.error ?? "none")",
                      "| context \(usage?.used ?? 0)/\(usage?.limit ?? 0)")
            }
            engine.prepare(mode: mode, for: chat)
            engine.send("In one sentence, what is a lantern?", in: chat)
            await idle()
            engine.send("Now say that in French.", in: chat)
            await idle()
            engine.retry(in: chat, mode: mode)
            await idle()
            engine.send("Count slowly from 1 to 200.", in: chat)
            try? await Task.sleep(for: .seconds(3))
            engine.stop()
            await idle()
            try? await Task.sleep(for: .seconds(1))  // the state is saved after the reply
            let saved = (try? FileManager.default.contentsOfDirectory(atPath: Engine.stateDirectory(for: chat).path)) ?? []
            let speed = engine.typicalSpeed(for: mode)
            print("ENGINETEST saved state: \(saved.sorted()), usually \(speed?.firstToken ?? -1) s, \(speed?.tokensPerSecond ?? -1) tok/s")
            engine.forgetState(for: chat)
            context.delete(chat)
            print("ENGINETEST done")
        }
    }
}
#endif

#if DEBUG
/// `-comparetest`: in an in-memory chat (no chats touched), asks a short question with E2B,
/// compares with E4B if it's downloaded or else the Mac's default model, then prints both
/// answers' `ReplyMetrics` and checks the pair, the vote and going back to A (its saved state must
/// be restored, not read again). Prints COMPARETEST lines (simctl launch --console).
@MainActor
enum CompareTest {
    private static var ran = false

    static func run(_ engine: Engine) async {
        guard ProcessInfo.processInfo.arguments.contains("-comparetest"), !ran else { return }
        ran = true
        guard let container = try? ModelContainer(
            for: Conversation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)) else { return }
        let chat = Conversation(mode: .fast)
        container.mainContext.insert(chat)
        func idle() async {
            repeat { try? await Task.sleep(for: .milliseconds(200)) } while engine.isBusy
        }
        func check(_ what: String, _ ok: Bool) { print("COMPARETEST \(ok ? "PASS" : "FAIL"): \(what)") }
        func dump(_ label: String, _ v: ReplyVersion) {
            let json = (try? JSONEncoder().encode(v.metrics)).map { String(decoding: $0, as: UTF8.self) } ?? "nil"
            print("COMPARETEST \(label): \(v.content.prefix(60).debugDescription) | error: \(v.error ?? "none")")
            print("COMPARETEST \(label) metrics: \(json)")
        }

        engine.send("In one sentence, what is a lantern?", in: chat)
        await idle()
        guard let a = chat.messages.last, a.error == nil, a.metrics != nil else {
            print("COMPARETEST A failed: \(chat.messages.last?.error ?? "no metrics")")
            return print("COMPARETEST done")
        }
        let other: ModelChoice
        if let e4b = engine.model(for: .smart), engine.store.states[e4b.id] == .ready {
            other = ModelChoice(mode: .smart, macModel: nil)
        } else {
            await engine.mac.resolve()
            other = ModelChoice(mode: .mac, macModel: engine.mac.modelName.isEmpty ? nil : engine.mac.modelName)
        }
        print("COMPARETEST comparing \(a.metrics?.modelTitle ?? "?") with \(other.title)")
        check("a model differing from A's is required", { engine.compare(in: chat, with: ModelChoice(mode: .fast, macModel: nil)); return !engine.isBusy }())
        engine.compare(in: chat, with: other)
        check("comparing is set while B runs", engine.comparing?.next == other && engine.isBusy)
        check("the chat is on B's model while it runs", chat.mode == other.mode)
        await idle()
        check("comparing is cleared after", engine.comparing == nil)
        guard let reply = chat.messages.last, let pair = reply.comparison else {
            check("the pair is found", false)
            return print("COMPARETEST done")
        }
        dump("A", pair.versions.0)
        dump("B", pair.versions.1)
        check("A comes before B, B is newest", pair.a < pair.b && pair.b == reply.allVersions.list.count - 1)
        check("B is shown, as Retry leaves it", reply.allVersions.current == pair.b)
        check("both share a compareID", pair.versions.0.metrics?.compareID != nil
              && pair.versions.0.metrics?.compareID == pair.versions.1.metrics?.compareID)
        check("B is B's model", pair.versions.1.metrics?.modeRaw == other.mode.rawValue)
        check("the chat continues with B's model, which wrote the shown answer", chat.mode == other.mode)
        check("first token leaves out loading",
              [pair.versions.0, pair.versions.1].allSatisfy { v in
                  guard let m = v.metrics, let first = m.firstTokenSeconds, let total = m.totalSeconds else { return v.error != nil }
                  return first + (m.loadSeconds ?? 0) <= total + 0.01
              })

        engine.vote(in: chat, preferring: pair.b)
        var voted = chat.messages.last!.comparison!
        check("vote B", voted.versions.1.metrics?.preferred == true && voted.versions.0.metrics?.preferred == false)
        engine.vote(in: chat, preferring: nil)
        voted = chat.messages.last!.comparison!
        check("vote cleared", voted.versions.1.metrics?.preferred == nil && voted.versions.0.metrics?.preferred == nil)

        engine.continueWith(in: chat, version: pair.a)
        check("A is shown", chat.messages.last?.allVersions.current == pair.a && chat.messages.last?.content == a.content)
        check("the chat is on A's model", chat.mode == .fast)
        // Let `prepare` finish loading, then drop the model so the follow-up has to come from A's
        // saved state, not memory.
        repeat { try? await Task.sleep(for: .milliseconds(500)) } while engine.loadingModel != nil
        try? await Task.sleep(for: .seconds(2))
        engine.unload()
        try? await Task.sleep(for: .seconds(1))
        engine.send("Now say that in French.", in: chat)
        await idle()
        let follow = chat.messages.last
        print("COMPARETEST follow-up: \(follow?.content.prefix(60).debugDescription ?? "") | error: \(follow?.error ?? "none")",
              "| reused \(follow?.metrics?.reusedTokens ?? -1) of \(follow?.metrics?.promptTokens ?? -1), restored \(follow?.metrics?.restored ?? false)")
        check("A's saved state was restored for the follow-up", follow?.metrics?.restored == true)

        // A B that produces nothing (a Mac model that doesn't exist) leaves A shown and no pair.
        if let shown = chat.messages.last, shown.error == nil, !shown.content.isEmpty {
            engine.compare(in: chat, with: ModelChoice(mode: .mac, macModel: "no-such-model:latest"))
            await idle()
            let after = chat.messages.last
            print("COMPARETEST failed B: \(after?.allVersions.list.last?.error ?? "no error")")
            check("a failed B shows A again", after?.content == shown.content && after?.error == nil)
            check("a failed B leaves no pair", after?.comparison == nil)
            check("a failed B puts the chat back on A's model", chat.mode == .fast)
        }
        engine.forgetState(for: chat)
        print("COMPARETEST done")
    }
}
#endif
