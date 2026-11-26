import SwiftData
import SwiftUI

/// Lantern on the Mac: chats with this Mac's model servers (through its own bridge), Lantern's own
/// models (llama.cpp) and Apple Intelligence, in windows with the chats in a sidebar. It also runs
/// `lantern-bridge` (the `Bridge/` Go module, built into the app), which serves this Mac's model
/// servers to paired iPhones and iPads, encrypted: from the menu bar, and from Settings › Devices.
/// Closing the last window leaves it in the menu bar, so the bridge keeps serving.
@main
struct LanternMacApp: App {
    static let mainWindow = "main"

    /// The chats, in a store of Lantern's own (the Mac app isn't sandboxed, so the default
    /// location would be shared with other apps).
    static let container: ModelContainer = {
        let folder = URL.applicationSupportDirectory.appending(path: "Lantern", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: folder.appending(path: "Chats.store"))
        do { return try ModelContainer(for: Conversation.self, configurations: configuration) } catch {
            fatalError("Couldn't open the chats: \(error)")
        }
    }()

    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    /// The app's one engine: shared by every window, and stopped by the delegate on Quit.
    static let engine = Engine()
    private var engine: Engine { Self.engine }
    /// One bridge for the app (an `App`'s `@State` can be built more than once).
    static let bridge = BridgeController()
    private var bridge: BridgeController { Self.bridge }

    init() {
        Conversation.repairActivity(in: Self.container.mainContext)
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
        WindowGroup("Lantern", id: Self.mainWindow, for: PersistentIdentifier.self) { $opened in
            MacRootView(opened: opened)
                .environment(engine)
                .environment(engine.store)
                .environment(engine.mac)
                .environment(bridge)
                .task(id: bridge.status?.fingerprint) {
                    // This Mac's model servers, through the bridge, once it runs.
                    await ThisMac.connect(engine.mac, bridge: bridge)
                }
        }
        .modelContainer(Self.container)
        .defaultSize(width: 1100, height: 760)
        .commands { MacCommands(engine: engine) }

        Settings {
            MacSettingsView()
                .environment(engine)
                .environment(engine.store)
                .environment(engine.mac)
                .environment(bridge)
        }

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
        Window("Menu Bar Panel", id: "debug-panel") {
            BridgeMenu()
                .environment(bridge)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Self.debugArgument("-panel") ? .presented : .suppressed)
        #endif
    }
}

/// Quit waits for the engine to stop and free its model (see `Engine.shutDown`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shuttingDown = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shuttingDown else { return .terminateNow }
        let engine = LanternMacApp.engine
        shuttingDown = true
        Task {
            await engine.shutDown()
            try? LanternMacApp.container.mainContext.save()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Closing the last window leaves Lantern in the menu bar, serving devices.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
