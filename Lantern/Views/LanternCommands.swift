import StoreKit
import SwiftUI

/// What the window can do, published by `RootView` with `focusedSceneValue` for the menu bar.
struct SceneActions {
    var newChat: () -> Void
    var showSettings: () -> Void
    var find: () -> Void
    var toggleSidebar: () -> Void
    var sidebarVisible: Bool
    /// The open chat's Think First and Search the Web; nil while they can't change.
    var thinking: Bool?
    var webSearch: Bool?
    var setThinking: (Bool) -> Void
    var setWebSearch: (Bool) -> Void
}

/// Opens something in the window (Settings, the model's page). Set by `RootView`, for views deep
/// inside the chat. Always equal: the closure only flips the window's state, so a newer copy does
/// the same thing.
struct OpenSheetAction: Equatable {
    let action: () -> Void
    init(_ action: @escaping () -> Void = {}) { self.action = action }
    func callAsFunction() { action() }
    static func == (_: Self, _: Self) -> Bool { true }
}

/// Shows a chat in the window. Set by `RootView`; always equal, like `OpenSheetAction`.
struct OpenChatAction: Equatable {
    let action: (Conversation) -> Void
    init(_ action: @escaping (Conversation) -> Void = { _ in }) { self.action = action }
    func callAsFunction(_ c: Conversation) { action(c) }
    static func == (_: Self, _: Self) -> Bool { true }
}

extension EnvironmentValues {
    /// Opens the page that downloads this device's model.
    @Entry var showModel = OpenSheetAction()
    @Entry var showSettings = OpenSheetAction()
    /// Settings › Mac: the paired Mac, or pairing with one.
    @Entry var showMacSettings = OpenSheetAction()
    @Entry var openChat = OpenChatAction()
}

extension FocusedValues {
    @Entry var sceneActions: SceneActions?
}

/// The menu bar (iPad and Mac) and its keyboard shortcuts. Send (Return) and Stop (Esc, ⌘.) are also
/// `UIKeyCommand`s on `ChatViewController`, so they work while the message box has focus; Stop
/// cancels the same one task either way.
struct LanternCommands: Commands {
    let engine: Engine
    @FocusedValue(\.sceneActions) private var actions
    #if targetEnvironment(macCatalyst)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Commands {
        #if targetEnvironment(macCatalyst)
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { MacUpdater.check() }
                .disabled(!MacUpdater.canCheck)
        }
        CommandGroup(replacing: .textFormatting) {}  // the Format menu: nothing to format
        #endif
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { actions?.newChat() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .appSettings) {
            #if targetEnvironment(macCatalyst)
            Button("Settings…") { SettingsWindow.shared.show(nil, open: openWindow) }
                .keyboardShortcut(",")
            #else
            Button("Settings…") { actions?.showSettings() }
                .keyboardShortcut(",")
                .disabled(actions == nil)
            #endif
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Chats") { actions?.find() }
                .keyboardShortcut("f")
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(actions?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") { actions?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(actions == nil)
        }
        CommandMenu("Chat") {
            Button("Stop") { engine.stop() }
                .keyboardShortcut(".")
                .disabled(engine.running == nil)
            Divider()
            Toggle("Think First", isOn: Binding(
                get: { actions?.thinking ?? false }, set: { actions?.setThinking($0) }))
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(actions?.thinking == nil)
            Toggle("Search the Web", isOn: Binding(
                get: { actions?.webSearch ?? false }, set: { actions?.setWebSearch($0) }))
                .disabled(actions?.webSearch == nil || !WebSearcher.hasKey)
        }
    }
}

/// TestFlight builds stop launching 90 days after upload. The build date is stamped into
/// Info.plist at build time; Settings shows the date.
enum BuildExpiry {
    /// Nil when installed from Xcode.
    static var date: Date? {
        guard State.shared.isTestFlight, let built = Bundle.main.object(forInfoDictionaryKey: "LanternBuildDate") as? Date else { return nil }
        return built.addingTimeInterval(90 * 86_400)
    }

    /// Within two weeks: Settings is badged.
    static var isSoon: Bool { date.map { $0.timeIntervalSinceNow < 14 * 86_400 } ?? false }

    /// Set at launch from StoreKit: TestFlight installs run in the sandbox environment. Observable,
    /// since it's only known after the first render.
    @Observable
    final class State {
        static let shared = State()
        fileprivate(set) var isTestFlight = false
    }

    static func checkEnvironment() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-testflight") {  // show the date in a build from Xcode
            State.shared.isTestFlight = true
            return
        }
        #endif
        if case .verified(let t)? = try? await AppTransaction.shared {
            State.shared.isTestFlight = t.environment == .sandbox
        }
    }
}
