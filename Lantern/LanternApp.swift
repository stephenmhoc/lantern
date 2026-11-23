import SwiftData
import SwiftUI

@main
struct LanternApp: App {
    /// The one window group. Opened with a chat's identifier for "Open in New Window", with none
    /// for an ordinary window. Every window shares `engine`, so one generation runs at a time.
    static let mainWindow = "main"

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
                #endif
        }
        .modelContainer(for: Conversation.self)
        .commands { LanternCommands(engine: engine) }
        .onChange(of: scenePhase) { _, phase in
            // The app's phase: background only once every window is.
            if phase == .background { engine.didEnterBackground() }
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
