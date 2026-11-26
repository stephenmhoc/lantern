import SwiftData
import SwiftUI

@main
struct LanternApp: App {
    static var container: ModelContainer { ChatStore.container }

    init() {
        Conversation.repairActivity(in: Self.container.mainContext)
        Conversation.repairModes(in: Self.container.mainContext)
    }

    @State private var engine = Engine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
                .environment(engine.store)
                .environment(engine.mac)
                .task { await BuildExpiry.checkEnvironment() }
                #if DEBUG
                .task { await EndToEnd.run(engine) }  // -e2e (scripts/e2e.sh)
                .task { await DebugPairing.run(engine) }  // -pairCode
                #endif
        }
        .modelContainer(Self.container)
        .commands { LanternCommands(engine: engine) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { engine.didEnterBackground() }
            if phase == .active { engine.didBecomeActive() }
        }
        // Lets the model's download finish while Lantern is in the background.
        .backgroundTask(.urlSession(ModelStore.sessionID)) {
            await withCheckedContinuation { continuation in
                Task { @MainActor in ModelStore.shared.onBackgroundEventsDone { continuation.resume() } }
            }
        }
        #if targetEnvironment(macCatalyst)
        // Settings, ⌘,: a window of its own, as Mac apps have.
        WindowGroup("Settings", id: SettingsWindow.id) {
            SettingsWindowView()
                .environment(engine)
                .environment(engine.store)
                .environment(engine.mac)
        }
        .modelContainer(Self.container)
        #endif
    }
}
