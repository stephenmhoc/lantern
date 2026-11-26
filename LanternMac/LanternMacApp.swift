import SwiftUI

/// Lantern on the Mac: for now, the way iPhones and iPads reach the models on this Mac. It lives in
/// the menu bar and runs `lantern-bridge` (the `Bridge/` Go module, built into the app), which
/// serves every local model server (Ollama, LM Studio…) to paired devices, encrypted.
@main
struct LanternMacApp: App {
    @State private var bridge = BridgeController()

    init() {
        #if DEBUG
        DebugSnapshot.scheduleIfAsked()
        #endif
    }

    private static func debugArgument(_ name: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(name)
        #else
        false
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            BridgeMenu()
                .environment(bridge)
        } label: {
            Image(systemName: "lightbulb.max")
        }
        .menuBarExtraStyle(.window)

        Window("Pair a Device", id: PairingView.windowID) {
            PairingView()
                .environment(bridge)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(Self.debugArgument("-pair") ? .presented : .suppressed)

        #if DEBUG
        // `-panel`: the menu bar panel in a window of its own, for screenshots.
        Window("Lantern", id: "debug-panel") {
            BridgeMenu()
                .environment(bridge)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Self.debugArgument("-panel") ? .presented : .suppressed)
        #endif
    }
}
