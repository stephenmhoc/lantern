import SwiftData
import SwiftUI

@main
struct LanternApp: App {
    @State private var engine = Engine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
                .environment(engine.store)
                .environment(engine.mac)
                .task { await Readiness.checkEnvironment() }
                #if DEBUG
                // `-selftest`: runs Readiness's Test on each downloaded model at launch and prints
                // the result, to check a build without tapping (simctl launch --console).
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("-selftest") else { return }
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { engine.didEnterBackground() }
        }
        // Lets model downloads finish while Lantern is in the background.
        .backgroundTask(.urlSession(ModelStore.sessionID)) {
            await withCheckedContinuation { continuation in
                Task { @MainActor in ModelStore.shared.onBackgroundEventsDone { continuation.resume() } }
            }
        }
    }
}
