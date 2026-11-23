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
            if ProcessInfo.processInfo.arguments.contains("-convert") {
                // Also convert whatever needs it first, as tapping Make faster in Readiness would.
                for model in CatalogModel.all where engine.store.unconverted.contains(model.id) {
                    engine.store.convert(model)
                    while case .converting = engine.store.states[model.id] { try? await Task.sleep(for: .seconds(1)) }
                    print("ENGINETEST converted \(model.name): \(engine.store.states[model.id] == .ready), still unconverted:",
                          engine.store.unconverted.contains(model.id), engine.store.conversionErrors[model.id] ?? "")
                }
            }
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
