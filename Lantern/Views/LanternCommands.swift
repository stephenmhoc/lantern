import LlamaKit
import SwiftData
import SwiftUI

/// What a window can do, published by `RootView` with `focusedSceneValue` so the menu bar reaches
/// the key window whether or not the sidebar is showing.
struct SceneActions {
    var newChat: () -> Void
    var showSettings: () -> Void
    var showReadiness: () -> Void
    var find: () -> Void
    /// Nil when no chat is selected.
    var deleteSelected: (() -> Void)?
    var previous: (() -> Void)?
    var next: (() -> Void)?
    /// Nil where there's no sidebar to hide (iPhone, compact width).
    var toggleSidebar: (() -> Void)?
    var sidebarVisible: Bool
}

/// The chat showing in the key window, published by `ChatScreen`.
struct ChatFocus {
    let conversation: Conversation
    let mode: Mode
    /// False while this chat is answering: its mode is fixed until the reply ends.
    let canChangeMode: Bool
}

/// Opens a sheet (Readiness or Settings) in this window. Set by `RootView`, for views deep inside the chat. Always equal:
/// the closure only flips the window's sheet state, so a newer copy does the same thing.
struct OpenSheetAction: Equatable {
    let action: () -> Void
    init(_ action: @escaping () -> Void = {}) { self.action = action }
    func callAsFunction() { action() }
    static func == (_: Self, _: Self) -> Bool { true }
}

/// Shows a chat in this window. Set by `RootView`; always equal, like `OpenSheetAction`.
struct OpenChatAction: Equatable {
    let action: (Conversation) -> Void
    init(_ action: @escaping (Conversation) -> Void = { _ in }) { self.action = action }
    func callAsFunction(_ c: Conversation) { action(c) }
    static func == (_: Self, _: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var showReadiness = OpenSheetAction()
    @Entry var showSettings = OpenSheetAction()
    @Entry var openChat = OpenChatAction()
}

extension FocusedValues {
    @Entry var sceneActions: SceneActions?
    @Entry var chat: ChatFocus?
}

/// The iPad menu bar and its keyboard shortcuts.
///
/// Mode (⌘1–4) and Stop (⌘.) also exist as `UIKeyCommand`s on `ChatViewController`, so they work
/// while the message box has focus. Both paths are idempotent (set a mode, cancel the one task),
/// so whichever UIKit routes the key to, it does the same thing once.
struct LanternCommands: Commands {
    let engine: Engine
    @FocusedValue(\.sceneActions) private var actions
    @FocusedValue(\.chat) private var chat
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { actions?.newChat() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            Button("New Window") { openWindow(id: LanternApp.mainWindow) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { actions?.showSettings() }
                .keyboardShortcut(",")
                .disabled(actions == nil)
            Button("Models") { actions?.showReadiness() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find in Chats") { actions?.find() }
                .keyboardShortcut("f")
                .disabled(actions == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Button(actions?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") { actions?.toggleSidebar?() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(actions?.toggleSidebar == nil)
        }

        CommandMenu("Chat") {
            Button("Previous Chat") { actions?.previous?() }
                .keyboardShortcut("[")
                .disabled(actions?.previous == nil)
            Button("Next Chat") { actions?.next?() }
                .keyboardShortcut("]")
                .disabled(actions?.next == nil)

            Divider()

            ForEach(Array(Mode.allCases.enumerated()), id: \.element) { i, mode in
                Toggle(mode.title, isOn: Binding(
                    get: { chat?.mode == mode },
                    set: { on in if on, let chat, chat.canChangeMode { chat.conversation.mode = mode } }
                ))
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                .disabled(chat?.canChangeMode != true)
            }
            Button("Stop") { engine.stop() }
                .keyboardShortcut(".")
                .disabled(engine.running == nil)

            Divider()

            Button("Delete Chat", role: .destructive) { actions?.deleteSelected?() }
                .keyboardShortcut(.delete)
                .disabled(actions?.deleteSelected == nil)
        }
    }
}
